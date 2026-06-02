;; Terminal transcript. The row looks like a tiny command session.

(def (dim ws)
  (if (get ws :dark-mode) (rgba 235 235 245 0.42) (rgba 60 60 67 0.45)))

(def (line prompt body tint)
  (hstack :spacing 6
    (text prompt
      :font (font :size 10 :weight bold :design monospaced)
      :foreground tint
      :width 16
      :frame-align trailing)
    (text body
      :font (font :size 10 :design monospaced)
      :line-limit 1
      :truncation middle)))

(def (pr-line pr)
  (button
    (line "gh" (str "pr view " (get pr :number) " --state " (get pr :state))
      (cond
        ((= (get pr :state) "merged") (color :purple))
        ((= (get pr :state) "closed") (color :red))
        (else (color :green))))
    :action (open-url (get pr :url))))

(def (render-row ws)
  (vstack :spacing 3 :max-width infinity :frame-align leading
    (line "$" (str "cd " (if (get ws :directory) (get ws :directory) (get ws :title))) (color :green))
    (line ">" (str "cmux workspace " (lower (replace (get ws :title) " " "-"))) (color :blue))
    (when (get ws :branch)
      (line "git" (str "branch --show-current  # " (get ws :branch)) (color :orange)))
    (map pr-line (get ws :pull-requests))
    (when (not (empty? (get ws :ports)))
      (line "http" (str "open " (join " " (get ws :ports))) (color :cyan)))
    (when (get ws :message)
      (line "log" (get ws :message) (dim ws)))
    (when (> (get ws :unread) 0)
      (line "!" (str (get ws :unread) " unread notifications") (color :red)))))

(def (workspace-block ws)
  (button
    (render-row ws)
    :action (select-workspace ws)
    :padding (edges :vertical 4)
    :max-width infinity
    :frame-align leading))

(def (render-sidebar sidebar)
  (vstack :spacing 4 :max-width infinity :frame-align leading
    (line "$" "cmux sidebar --mode lisp" (color :green))
    (line ">" (str "workspaces=" (get sidebar :workspace-count)) (color :blue))
    (divider :opacity 0.4)
    (map workspace-block (get sidebar :workspaces))
    (button
      (line "$" "cmux new-workspace Scratch" (color :green))
      :action (new-workspace :title "Scratch"))
    :padding (edges :horizontal 9 :vertical 10)
    :background (rgba 0 0 0 0.82)))
