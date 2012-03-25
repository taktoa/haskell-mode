;;; haskell-process.el -- Communicating with the inferior Haskell process.

;; Copyright (C) 2011-2012 Chris Done

;; Author: Chris Done <chrisdone@gmail.com>

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;;; Todo:

;;; Code:

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Configuration

(defcustom haskell-process-path-ghci
  (or (cond
       ((not (fboundp 'executable-find)) nil)
       ((executable-find "hugs") "hugs \"+.\"")
       ((executable-find "ghci") "ghci"))
      "ghci")
  "The path for starting ghci."
  :group 'haskell
  :type '(choice string (repeat string)))

(defcustom haskell-process-path-cabal-dev
  "cabal-dev"
  "The path for starting cabal-dev."
  :group 'haskell
  :type '(choice string (repeat string)))

(defcustom haskell-process-type
  'ghci
  "The inferior Haskell process type to use."
  :options '(ghci cabal-dev)
  :type 'symbol
  :group 'haskell)

(defvar haskell-process-prompt-regex "\\(^[> ]*> $\\|\n[> ]*> $\\)")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Specialised commands

(defun haskell-process-do-type ()
  "Print the type of the given expression."
  (interactive)
  (haskell-process-do-simple-echo
   (format ":type %s" (haskell-ident-at-point))))

(defun haskell-process-do-info ()
  "Print the info of the given expression."
  (interactive)
  (haskell-process-do-simple-echo
   (format ":info %s" (haskell-ident-at-point))))

(defun haskell-process-do-simple-echo (line)
  "Send some line to GHCi and echo the result in the REPL and minibuffer."
  (let ((process (haskell-process)))
    (haskell-process-queue-command
     process
     (haskell-command-make
      process
      (lambda (process)
        (haskell-process-send-string process line))
      nil
      (lambda (process response)
        (haskell-interactive-mode-echo (haskell-process-session process)
                                       response)
        (haskell-mode-message-line response))))))

;;;###autoload
(defun haskell-process-load-file ()
  "Load the current buffer file."
  (interactive)
  (save-buffer)
  (let ((file-path (buffer-file-name))
        (session (haskell-session))
        (process (haskell-process)))
    (haskell-session-current-dir session)
    (haskell-process-queue-command
     process
     (haskell-command-make 
      (list session process file-path)
      (lambda (state)
        (haskell-process-send-string (cadr state)
                                     (format ":load %s" (caddr state))))
      (lambda (state buffer)
        (or (haskell-process-live-load-file (cadr state) buffer)
            (haskell-process-live-load-packages (cadr state) buffer)))
      (lambda (state response)
        (haskell-process-load-complete (car state) response))))))

;;;###autoload
(defun haskell-process-cabal-build ()
  "Build the Cabal project."
  (interactive)
  (haskell-process-do-cabal "build"))

;;;###autoload
(defun haskell-process-cabal ()
  "Prompts for a Cabal command to run."
  (interactive)
  (haskell-process-do-cabal
   (ido-completing-read "Cabal command: "
                        haskell-cabal-commands)))

(defun haskell-process-do-cabal (command)
  "Run a Cabal command."
  (let ((process (haskell-process)))
    (haskell-process-queue-command
     process
     (haskell-command-make
      (list (haskell-session) process command 0)
      (lambda (state)
        (haskell-process-send-string
         (cadr state)
         (format ":!%s && %s"
                 (format "cd %s" (haskell-session-cabal-dir (car state)))
                 (format "%s %s"
                         (ecase haskell-process-type
                           ('ghci "cabal")
                           ('cabal-dev "cabal-dev"))
                         (caddr state)))))
      (lambda (state buffer)
        (haskell-interactive-mode-insert
         (haskell-process-session (cadr state))
         (replace-regexp-in-string
          haskell-process-prompt-regex
          ""
          (substring buffer (cadddr state))))
        (setf (cdddr state) (list (length buffer)))
        nil)
      (lambda (state _)
        (haskell-interactive-mode-echo (haskell-process-session (cadr state))
                                       "Command complete."))))))

(defun haskell-process-load-complete (session response)
  "Handle the complete loading response."
  (cond ((haskell-process-consume process "Ok, modules loaded: \\(.+\\)$")
         (let ((cursor (haskell-process-response-cursor process)))
           (haskell-process-set-response-cursor process 0)
           (let ((warning-count 0))
             (while (haskell-process-errors-warnings session process)
               (setq warning-count (1+ warning-count)))
             (haskell-process-set-response-cursor process cursor)
             (haskell-mode-message-line "OK."))))
        ((haskell-process-consume process "Failed, modules loaded: \\(.+\\)$")
         (let ((cursor (haskell-process-response-cursor process)))
           (haskell-process-set-response-cursor process 0)
           (while (haskell-process-errors-warnings session process))
           (haskell-process-set-response-cursor process cursor)
           (haskell-mode-message-line "Compilation failed.")
           (haskell-interactive-mode-echo session "Compilation failed.")))))

(defun haskell-process-live-load-file (process buffer)
  "Show live updates for loading files."
  (cond ((haskell-process-consume
          process
          (concat "\\[\\([0-9]+\\) of \\([0-9]+\\)\\]"
                  " Compiling \\([^ ]+\\)[ ]+"
                  "( \\([^ ]+\\), \\([^ ]+\\) )[\r\n]+"))
         (haskell-interactive-show-load-message
          (haskell-process-session process)
          'compiling
          (match-string 3 buffer)
          (match-string 4 buffer)
          nil)
         t)))

(defun haskell-process-live-load-packages (process buffer)
  "Show live package loading updates."
  (cond ((haskell-process-consume process "Loading package \\([^ ]+\\) ... linking ... done.\n")
         (haskell-mode-message-line
          (format "Loading: %s"
                  (match-string 1 buffer))))))

(defun haskell-process-errors-warnings (session buffer)
  "Trigger handling type errors or warnings."
  (cond
   ((haskell-process-consume
     process
     (concat "[\r\n]\\([^ \r\n:][^:\n\r]+\\):\\([0-9]+\\):\\([0-9]+\\):"
             "[ \n\r]+\\([[:unibyte:][:nonascii:]]+?\\)\n[^ ]"))
    (haskell-process-set-response-cursor process
                                         (- (haskell-process-response-cursor process) 1))
    (let* ((buffer (haskell-process-response process))
           (error-msg (match-string 4 buffer))
           (file (match-string 1 buffer))
           (line (match-string 2 buffer))
           (col (match-string 3 buffer))
           (warning (string-match "^Warning: " error-msg))
           (final-msg (format "%s:%s:%s: %s" 
                              (haskell-session-strip-dir session file)
                              line
                              col
                              error-msg)))
      (haskell-interactive-mode-echo session final-msg)
      (unless warning
        (haskell-mode-message-line final-msg)))
    t)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Building the process

;;;###autoload
(defun haskell-process-start (session)
  "Start the inferior Haskell process."
  (let ((process (haskell-process-make (haskell-session-name session))))
    (haskell-session-set-process session process)
    (haskell-process-set-session process session)
    (let ((default-directory (haskell-session-cabal-dir session)))
      (haskell-process-set-process
       process
       (ecase haskell-process-type
         ('ghci 
          (haskell-process-log (format "Starting inferior GHCi process %s ..."
                                       haskell-process-path-ghci))
          (start-process (haskell-session-name session)
                         nil
                         haskell-process-path-ghci))
         ('cabal-dev
          (let ((dir (concat (haskell-session-cabal-dir session)
                             "/cabal-dev")))
            (haskell-process-log (format "Starting inferior cabal-dev process %s -s %s ..."
                                         haskell-process-path-cabal-dev
                                         dir))
            (start-process (haskell-session-name session)
                           nil
                           haskell-process-path-cabal-dev
                           "ghci"
                           "-s"
                           dir))))))
    (progn (set-process-sentinel (haskell-process-process process) 'haskell-process-sentinel)
           (set-process-filter (haskell-process-process process) 'haskell-process-filter))
    (haskell-process-send-startup process)
    (when (haskell-session-current-dir session)
      (haskell-process-change-dir session
                                  process
                                  (haskell-session-current-dir session)))
    process))

(defun haskell-process-restart ()
  "Restart the inferior Haskell process."
  (interactive)
  (haskell-process-start (haskell-session)))

(defun haskell-process-make (name)
  "Make an inferior Haskell process."
  (list (cons 'name name)
        (cons 'current-command
              (haskell-command-make nil nil nil nil))))

;;;###autoload
(defun haskell-process ()
  "Get the current process from the current session."
  (haskell-session-process (haskell-session)))

(defun haskell-process-interrupt ()
  "Interrupt the process (SIGINT)."
  (interactive)
  (interrupt-process (haskell-process-process (haskell-process))))

(defun haskell-process-cd (&optional not-interactive)
  "Change directory."
  (interactive)
  (let* ((session (haskell-session))
         (dir (read-from-minibuffer
               "Set current directory: "
               (or (haskell-session-get session 'current-dir)
                   (if (buffer-file-name)
                       (file-name-directory (buffer-file-name))
                     "~/")))))
    (haskell-process-log (format "Changing directory to %s ...\n" dir))
    (haskell-process-change-dir session
                                (haskell-process)
                                dir)))

(defun haskell-process-change-dir (session process dir)
  "Change the directory of the current process."
  (haskell-process-queue-command
   process
   (haskell-command-make
    (list session process dir)
    (lambda (state)
      (haskell-process-send-string (cadr state) (format ":cd %s" (caddr state))))
    nil
    (lambda (state _)
      (haskell-session-set-current-dir (car state) (caddr state))
      (haskell-interactive-mode-echo (car state)
                                     (format "Changed directory: %s"
                                             (caddr state)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Process communication

(defun haskell-process-send-startup (process)
  "Send the necessary start messages."
  (haskell-process-queue-command
   process
   (haskell-command-make process
                         (lambda (process) (haskell-process-send-string process ":set prompt \"> \""))
                         nil
                         nil))
  (haskell-process-queue-command
   process
   (haskell-command-make process
                         (lambda (process) (haskell-process-send-string process ":set -v1"))
                         nil
                         (lambda (process _)
                           (haskell-interactive-mode-echo
                            (haskell-process-session process)
                            (nth (random (length haskell-interactive-greetings))
                                 haskell-interactive-greetings))))))

(defun haskell-process-sentinel (proc event)
  "The sentinel for the process pipe."
  (let ((session (haskell-process-project-by-proc proc)))
    (when session
      (let ((process (haskell-session-process session)))
        (haskell-process-reset process)
        (haskell-process-log (format "Event: %S\n" event))
        (haskell-process-log "Process reset.\n")
        (haskell-process-prompt-restart process)))))

(defun haskell-process-filter (proc response)
  "The filter for the process pipe."
  (haskell-process-log (format "<- %S\n" response))
  (let ((session (haskell-process-project-by-proc proc)))
    (when session
      (when (not (eq (haskell-process-cmd (haskell-session-process session))
                     'none))
        (haskell-process-collect session
                                 response
                                 (haskell-session-process session)
                                 'main)))))

(defun haskell-process-log (out)
  "Log to the process log."
  (with-current-buffer (get-buffer-create "*haskell-process-log*")
    (goto-char (point-max))
    (insert out)))

(defun haskell-process-project-by-proc (proc)
  "Find project by process."
  (find-if (lambda (project)
             (string= (haskell-session-name project)
                      (process-name proc)))
           haskell-sessions))

(defun haskell-process-collect (session response process type)
  "Collect input for the response until receives a prompt."
  (haskell-process-set-response process
                                (concat (haskell-process-response process) response))
  (while (haskell-process-live-updates session process))
  (when (string-match haskell-process-prompt-regex
                      (haskell-process-response process))
    (haskell-command-complete
     (haskell-process-cmd process)
     (replace-regexp-in-string
      haskell-process-prompt-regex
      ""
      (haskell-process-response process)))
    (haskell-process-reset process)
    (haskell-process-trigger-queue process)))

(defun haskell-process-reset (process)
  "Reset the process's state, ready for the next send/reply."
  (progn (haskell-process-set-response-cursor process 0)
         (haskell-process-set-response process "")
         (haskell-process-set-cmd process 'none)))

(defun haskell-process-consume (process regex)
  "Consume a regex from the response and move the cursor along if succeed."
  (when (string-match regex
                      (haskell-process-response process)
                      (haskell-process-response-cursor process))
    (haskell-process-set-response-cursor process (match-end 0))
    t))

(defun haskell-process-send-string (process string)
  "Try to send a string to the process's process. Ask to restart if it's not running."
  (let ((child (haskell-process-process process)))
    (if (equal 'run (process-status child))
        (let ((out (concat string "\n")))
          (haskell-process-log (format "-> %S\n" out))
          (process-send-string child out))
      (haskell-process-prompt-restart process))))

(defun haskell-process-prompt-restart (process)
  "Prompt to restart the died process."
  (when (y-or-n-p (format "The Haskell process `%s' has died. Restart? "
                          (haskell-process-name process)))
    (haskell-process-start (haskell-process-session process))))

(defun haskell-process-live-updates (session process)
  "Process live updates."
  (haskell-command-live (haskell-process-cmd process)
                        (haskell-process-response process)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Making commands

(defun haskell-process-queue-command (process command)
  "Add a command to the process command queue."
  (haskell-process-add-to-cmd-queue process command)
  (haskell-process-trigger-queue process))

(defun haskell-process-trigger-queue (process)
  "Trigger the next command in the queue to be ran if there is no current command."
  (if (haskell-process-process process)
      (when (equal (haskell-process-cmd process) 'none)
        (let ((cmd (haskell-process-cmd-queue-pop process)))
          (when cmd
            (haskell-process-set-cmd process cmd)
            (haskell-command-go cmd))))
    (progn (haskell-process-log "Process died or never started. Starting...\n")
           (haskell-process-start (haskell-process-session process)))))

(defun haskell-command-make (state go live complete)
  "Make a process command of the given `type' with the given `go' procedure."
  (list (cons 'state state)
        (cons 'go go)
        (cons 'live live)
        (cons 'complete complete)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Accessing the process

(defun haskell-process-set-process (p v)
  "Set the process's inferior process."
  (haskell-process-set p 'inferior-process v))

(defun haskell-process-process (p)
  "Get the process child."
  (haskell-process-get p 'inferior-process))

(defun haskell-process-name (p)
  "Get the process name."
  (haskell-process-get p 'name))

(defun haskell-process-cmd (p)
  "Get the process's current command."
  (haskell-process-get p 'current-command))

(defun haskell-process-set-cmd (p v)
  "Set the process's current command."
  (haskell-process-set p 'current-command v))

(defun haskell-process-response (p)
  "Get the process's current response."
  (haskell-process-get p 'current-response))

(defun haskell-process-session (p)
  "Get the process's current session."
  (haskell-process-get p 'session))

(defun haskell-process-set-response (p v)
  "Set the process's current response."
  (haskell-process-set p 'current-response v))

(defun haskell-process-set-session (p v)
  "Set the process's current session."
  (haskell-process-set p 'session v))

(defun haskell-process-response-cursor (p)
  "Get the process's current response cursor."
  (haskell-process-get p 'current-response-cursor))

(defun haskell-process-set-response-cursor (p v)
  "Set the process's response cursor."
  (haskell-process-set p 'current-response-cursor v))

(defun haskell-process-add-to-cmd-queue (process cmd)
  "Set the process's response cursor."
  (haskell-process-set process
                       'command-queue
                       (append (haskell-process-cmd-queue process)
                               (list cmd))))

(defun haskell-process-cmd-queue (process)
  "Get the process's command queue."
  (haskell-process-get process 'command-queue))

(defun haskell-process-cmd-queue-pop (process)
  "Get the process's command queue."
  (let ((queue (haskell-process-get process 'command-queue)))
    (unless (null queue)
      (let ((next (car queue)))
        (haskell-process-set process 'command-queue (cdr queue))
        next))))

(defun haskell-process-get (s key)
  "Get the process `key'."
  (let ((x (assoc key s)))
    (when x
      (cdr x))))

(defun haskell-process-set (s key value) 
  "Set the process's `key'."
  (delete-if (lambda (prop) (equal (car prop) key)) s)
  (setf (cdr s) (cons (cons key value)
                      (cdr s)))
  s)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Accessing commands

(defun haskell-command-type (s)
  "Get the command's type."
  (haskell-command-get s 'type))

(defun haskell-command-state (s)
  "Get the command's state."
  (haskell-command-get s 'state))

(defun haskell-command-go (s)
  "Call the command's go function."
  (let ((func (haskell-command-get s 'go)))
    (when func
      (funcall func 
               (haskell-command-state s)))))

(defun haskell-command-complete (s response)
  "Call the command's complete function."
  (let ((func (haskell-command-get s 'complete)))
    (when func
      (funcall func
               (haskell-command-state s)
               response))))

(defun haskell-command-live (s response)
  "Trigger the command's live updates callback."
  (let ((func (haskell-command-get s 'live)))
    (when func
      (funcall func 
               (haskell-command-state s)
               response))))

(defun haskell-command-get (s key)
  "Get the command `key'."
  (let ((x (assoc key s)))
    (when x
      (cdr x))))

(defun haskell-command-set (s key value) 
  "Set the command's `key'."
  (delete-if (lambda (prop) (equal (car prop) key)) s)
  (setf (cdr s) (cons (cons key value)
                      (cdr s)))
  s)
