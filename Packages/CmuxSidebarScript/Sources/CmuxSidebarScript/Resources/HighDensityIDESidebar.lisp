;; Compact IDE-style rows: small type, edge-to-edge structure, dense metadata.

(def (muted ws)
  (if (get ws :dark-mode) (rgba 235 235 245 0.48) (rgba 60 60 67 0.55)))

(def (state-color pr)
  (cond
    ((= (get pr :state) "merged") (color :purple))
    ((= (get pr :state) "closed") (color :red))
    ((get pr :draft) (color :gray))
    (else (color :green))))

(def (short-path path)
  (if (> (string-length path) 28)
      (str "..." (substring path (- (string-length path) 25)))
      path))

(def (pr-token pr)
  (button
    (hstack :spacing 3
      (circle :fill (state-color pr) :width 5 :height 5)
      (text (str (get pr :number))
        :font (font :size 10 :weight medium :design monospaced)
        :foreground (state-color pr)))
    :action (open-url (get pr :url))
    :help (get pr :title)))

(def (status-token item)
  (text (str (get item :label) ":" (get item :value))
    :font (font :size 9 :design monospaced)
    :foreground (if (get item :color) (hex (get item :color)) (color :secondary))
    :line-limit 1))

(def (render-row ws)
  (vstack :spacing 2 :max-width infinity :frame-align leading
    (hstack :spacing 4
      (image :system (if (get ws :pinned) "pin.fill" "terminal")
        :font (font :size 10)
        :foreground (muted ws))
      (text (get ws :title)
        :font (font :size 11 :weight medium)
        :line-limit 1
        :truncation tail)
      (spacer)
      (when (> (get ws :unread) 0)
        (text (str (get ws :unread))
          :font (font :size 9 :weight bold :monospaced-digit true)
          :foreground (color :red))))
    (hstack :spacing 6
      (when (get ws :branch)
        (label :system "arrow.triangle.branch" :text (get ws :branch)
          :font (font :size 10 :design monospaced)
          :foreground (muted ws)
          :line-limit 1
          :truncation middle))
      (when (get ws :directory)
        (text (short-path (get ws :directory))
          :font (font :size 10 :design monospaced)
          :foreground (muted ws)
          :line-limit 1
          :truncation head)))
    (when (or (not (empty? (get ws :pull-requests))) (not (empty? (get ws :status))))
      (hstack :spacing 7
        (map pr-token (get ws :pull-requests))
        (map status-token (get ws :status))))
    (when (not (empty? (get ws :ports)))
      (text (str "ports " (join " " (get ws :ports)))
        :font (font :size 9 :design monospaced)
        :foreground (color :blue)
        :line-limit 1))
    (when (get ws :progress)
      (progress-view :value (get ws :progress) :total 1 :tint (color :blue)))))
