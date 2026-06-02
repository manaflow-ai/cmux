;; Chunkier "pro app" row with large title, pill metadata, and layered badges.

(def (accent ws)
  (if (get ws :color) (hex (get ws :color)) (rgba 255 159 10 1)))

(def (muted ws)
  (if (get ws :dark-mode) (rgba 235 235 245 0.58) (rgba 60 60 67 0.58)))

(def (pill label system fill)
  (hstack :spacing 4
    (image :system system :font (font :size 9 :weight semibold))
    (text label :font (font :size 10 :weight semibold))
    :foreground (color :white)
    :padding (edges :horizontal 7 :vertical 3)
    :background fill
    :corner-radius 10))

(def (pr-card pr)
  (button
    (hstack :spacing 5
      (image :system (if (get pr :draft) "doc.badge.clock" "arrow.triangle.pull")
        :font (font :size 10 :weight semibold))
      (text (str "#" (get pr :number))
        :font (font :size 11 :weight bold :design monospaced)))
    :action (open-url (get pr :url))
    :foreground (color :white)
    :padding (edges :horizontal 7 :vertical 4)
    :background (cond
      ((= (get pr :state) "merged") (color :purple))
      ((= (get pr :state) "closed") (color :red))
      ((get pr :draft) (color :gray))
      (else (color :green)))
    :corner-radius 8))

(def (port-card port)
  (button
    (label :system "network" :text (str port)
      :font (font :size 10 :weight bold :design monospaced))
    :action (open-url (str "http://localhost:" port))
    :foreground (color :white)
    :padding (edges :horizontal 7 :vertical 4)
    :background (rgba 10 132 255 0.88)
    :corner-radius 8))

(def (render-row ws)
  (vstack :spacing 7 :max-width infinity :frame-align leading
    (hstack :spacing 7
      (zstack
        (rounded-rectangle :radius 8 :fill (accent ws) :width 30 :height 30 :opacity 0.22)
        (rounded-rectangle :radius 8 :stroke (accent ws) :stroke-width 1 :width 30 :height 30)
        (image :system (if (get ws :active) "play.fill" "square.stack.3d.up")
          :font (font :size 13 :weight black)
          :foreground (accent ws)))
      (vstack :spacing 1 :max-width infinity :frame-align leading
        (text (get ws :title)
          :font (font :size 14 :weight bold)
          :line-limit 1
          :truncation tail)
        (when (get ws :detail)
          (text (get ws :detail)
            :font (font :size 11 :weight medium)
            :foreground (muted ws)
            :line-limit 1
            :truncation tail)))
      (when (> (get ws :unread) 0)
        (pill (str (get ws :unread)) "bell.fill" (color :red))))
    (hstack :spacing 5
      (when (get ws :branch) (pill (get ws :branch) "arrow.triangle.branch" (rgba 255 159 10 0.85)))
      (when (get ws :remote) (pill (get ws :remote) "antenna.radiowaves.left.and.right" (rgba 52 199 89 0.78))))
    (when (get ws :directory)
      (label :system "folder.fill" :text (get ws :directory)
        :font (font :size 11 :weight medium)
        :foreground (muted ws)
        :line-limit 1
        :truncation head))
    (when (or (not (empty? (get ws :pull-requests))) (not (empty? (get ws :ports))))
      (hstack :spacing 5
        (map pr-card (get ws :pull-requests))
        (map port-card (get ws :ports))))
    (when (get ws :progress)
      (progress-view :value (get ws :progress) :total 1 :tint (accent ws)))))
