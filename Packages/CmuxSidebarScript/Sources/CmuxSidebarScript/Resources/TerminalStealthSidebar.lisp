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
