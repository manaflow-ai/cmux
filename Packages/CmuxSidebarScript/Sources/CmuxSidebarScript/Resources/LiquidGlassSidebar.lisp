;; Rounded, translucent row content inspired by the existing Liquid Glass file
;; explorer style. cmux still owns the outer selection chrome.

(def (secondary ws)
  (if (get ws :dark-mode) (rgba 235 235 245 0.62) (rgba 60 60 67 0.62)))

(def (accent ws)
  (if (get ws :color) (hex (get ws :color)) (color :accent)))

(def (badge label fill)
  (text label
    :font (font :size 9 :weight semibold :monospaced-digit true)
    :foreground (color :white)
    :padding (edges :horizontal 5 :vertical 2)
    :background fill
    :corner-radius 8))

(def (count-pill system value fill)
  (when (> value 0)
    (hstack :spacing 3
      (image :system system :font (font :size 8 :weight semibold))
      (text (str value) :font (font :size 9 :weight semibold :monospaced-digit true))
      :foreground (color :white)
      :padding (edges :horizontal 6 :vertical 2)
      :background fill
      :corner-radius 9)))

(def (branch-pill ws)
  (when (get ws :branch)
    (hstack :spacing 4
      (image :system "arrow.triangle.branch" :font (font :size 9 :weight medium))
      (text (get ws :branch)
        :font (font :size 10 :weight medium :design monospaced)
        :line-limit 1
        :truncation middle)
      :foreground (secondary ws)
      :padding (edges :horizontal 6 :vertical 3)
      :background (rounded-rectangle :radius 8 :fill (rgba 127 127 127 0.13))
      :overlay (rounded-rectangle :radius 8 :stroke (rgba 255 255 255 0.12) :stroke-width 1))))

(def (pr-dot pr)
  (circle
    :fill (cond
      ((= (get pr :state) "merged") (color :purple))
      ((= (get pr :state) "closed") (color :red))
      ((get pr :draft) (color :gray))
      (else (color :green)))
    :width 6
    :height 6))

(def (pr-chip pr)
  (button
    (hstack :spacing 4
      (pr-dot pr)
      (text (str "#" (get pr :number))
        :font (font :size 10 :weight medium :design monospaced)
        :line-limit 1))
    :action (open-url (get pr :url))
    :padding (edges :horizontal 6 :vertical 2)
    :background (rgba 127 127 127 0.12)
    :corner-radius 7))

(def (ports ws)
  (when (not (empty? (get ws :ports)))
    (hstack :spacing 4
      (map (fn (port)
        (badge (str port) (rgba 10 132 255 0.85)))
        (get ws :ports)))))

(def (render-row ws)
  (vstack :spacing 6 :max-width infinity :frame-align leading
    (hstack :spacing 6
      (zstack
        (circle :fill (accent ws) :width 18 :height 18 :opacity 0.28)
        (image :system (if (get ws :active) "sparkle" "macwindow")
          :font (font :size 10 :weight semibold)
          :foreground (accent ws)))
      (text (get ws :title)
        :font (font :size 13 :weight semibold)
        :line-limit 1
        :truncation tail)
      (spacer)
      (count-pill "bell.fill" (get ws :unread) (color :red)))
    (when (get ws :detail)
      (text (get ws :detail)
        :font (font :size 11)
        :foreground (secondary ws)
        :line-limit 2))
    (hstack :spacing 5
      (branch-pill ws)
      (when (get ws :remote)
        (badge (get ws :remote) (rgba 52 199 89 0.78))))
    (when (not (empty? (get ws :pull-requests)))
      (hstack :spacing 4 (map pr-chip (get ws :pull-requests))))
    (ports ws)
    (when (get ws :progress)
      (progress-view :value (get ws :progress) :total 1 :tint (accent ws)))))
