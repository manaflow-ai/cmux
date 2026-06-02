;; Finder-like rows with filled icons, rounded selections inside the content, and
;; hover-friendly spacing.

(def (muted ws)
  (if (get ws :dark-mode) (rgba 235 235 245 0.56) (rgba 60 60 67 0.56)))

(def (folder-symbol ws)
  (cond
    ((get ws :pinned) "pin.fill")
    ((get ws :remote) "externaldrive.connected.to.line.below.fill")
    ((not (empty? (get ws :ports))) "network")
    (else "folder.fill")))

(def (branch ws)
  (when (get ws :branch)
    (hstack :spacing 4
      (image :system "arrow.triangle.branch" :font (font :size 10 :weight medium))
      (text (get ws :branch)
        :font (font :size 11)
        :line-limit 1
        :truncation middle)
      :foreground (muted ws))))

(def (pr-count ws)
  (let ((open (count (filter (fn (pr) (= (get pr :state) "open")) (get ws :pull-requests)))))
    (when (> open 0)
      (text (str open)
        :font (font :size 11 :weight semibold :monospaced-digit true)
        :foreground (color :white)
        :padding (edges :horizontal 6 :vertical 1)
        :background (color :blue)
        :corner-radius 8))))

(def (status-row item ws)
  (hstack :spacing 5
    (circle :fill (if (get item :color) (hex (get item :color)) (color :green)) :width 6 :height 6)
    (text (get item :label)
      :font (font :size 10)
      :foreground (muted ws)
      :line-limit 1)
    (spacer)
    (text (get item :value)
      :font (font :size 10 :weight medium)
      :foreground (color :primary)
      :line-limit 1)))

(def (render-row ws)
  (vstack :spacing 5 :max-width infinity :frame-align leading
    (hstack :spacing 7
      (image :system (folder-symbol ws)
        :font (font :size 16 :weight medium)
        :foreground (if (get ws :active) (color :accent) (color :blue))
        :frame-align center
        :width 19)
      (text (get ws :title)
        :font (font :size 13 :weight medium)
        :line-limit 1
        :truncation tail)
      (spacer)
      (pr-count ws)
      (when (> (get ws :unread) 0)
        (text (str (get ws :unread))
          :font (font :size 11 :weight semibold :monospaced-digit true)
          :foreground (color :red))))
    (hstack :spacing 8
      (branch ws)
      (when (get ws :directory)
        (text (get ws :directory)
          :font (font :size 11)
          :foreground (muted ws)
          :line-limit 1
          :truncation head)))
    (when (not (empty? (get ws :status)))
      (vstack :spacing 2 :max-width infinity :frame-align leading
        (map (fn (entry) (status-row entry ws)) (get ws :status))))
    (when (get ws :progress)
      (progress-view :value (get ws :progress) :total 1 :tint (color :blue)))))
