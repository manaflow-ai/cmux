;; Desaturated, monospaced rows for terminal-heavy workspaces.

(def (ink ws)
  (if (get ws :active) (color :primary) (if (get ws :dark-mode) (rgba 235 235 245 0.7) (rgba 60 60 67 0.7))))

(def (dim ws)
  (if (get ws :dark-mode) (rgba 235 235 245 0.42) (rgba 60 60 67 0.45)))

(def (prompt ws)
  (if (get ws :active) ">" "$"))

(def (line label value ws)
  (when value
    (hstack :spacing 6
      (text label
        :font (font :size 10 :weight medium :design monospaced)
        :foreground (dim ws)
        :frame-align trailing
        :width 28)
      (text value
        :font (font :size 10 :design monospaced)
        :foreground (ink ws)
        :line-limit 1
        :truncation middle))))

(def (pr-line pr)
  (button
    (hstack :spacing 6
      (text "pr"
        :font (font :size 10 :weight medium :design monospaced)
        :foreground (color :secondary)
        :frame-align trailing
        :width 28)
      (text (str "#" (get pr :number) " " (get pr :state))
        :font (font :size 10 :design monospaced)
        :foreground (cond
          ((= (get pr :state) "merged") (color :purple))
          ((= (get pr :state) "closed") (color :red))
          (else (color :green)))
        :line-limit 1))
    :action (open-url (get pr :url))))

(def (render-row ws)
  (vstack :spacing 3 :max-width infinity :frame-align leading
    (hstack :spacing 6
      (text (prompt ws)
        :font (font :size 12 :weight bold :design monospaced)
        :foreground (if (get ws :active) (color :green) (dim ws)))
      (text (lower (replace (get ws :title) " " "-"))
        :font (font :size 12 :weight medium :design monospaced)
        :foreground (ink ws)
        :line-limit 1
        :truncation tail)
      (spacer)
      (when (> (get ws :unread) 0)
        (text (pad-left (get ws :unread) 2 "0")
          :font (font :size 10 :weight bold :design monospaced)
          :foreground (color :orange))))
    (line "git" (get ws :branch) ws)
    (line "cwd" (get ws :directory) ws)
    (when (get ws :remote) (line "ssh" (get ws :remote) ws))
    (map pr-line (get ws :pull-requests))
    (when (not (empty? (get ws :ports)))
      (line "http" (join "," (get ws :ports)) ws))
    (when (get ws :message)
      (text (get ws :message)
        :font (font :size 10 :design monospaced)
        :foreground (dim ws)
        :line-limit 1
        :truncation tail))
    (when (get ws :progress)
      (progress-view :value (get ws :progress) :total 1 :tint (color :green)))))
