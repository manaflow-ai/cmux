;; A user-provided-style ops dashboard: row content becomes a compact status
;; console for ports, PRs, remote targets, messages, and progress.

(def (muted ws)
  (if (get ws :dark-mode) (rgba 235 235 245 0.55) (rgba 60 60 67 0.58)))

(def (accent ws)
  (if (get ws :active) (color :green) (if (get ws :color) (hex (get ws :color)) (color :accent))))

(def (metric title value color)
  (vstack :spacing 1 :frame-align leading
    (text title
      :font (font :size 8 :weight bold :design monospaced)
      :foreground (rgba 180 180 190 0.75)
      :line-limit 1)
    (text value
      :font (font :size 12 :weight black :design monospaced)
      :foreground color
      :line-limit 1)
    :padding (edges :horizontal 7 :vertical 5)
    :background (rounded-rectangle :radius 8 :fill (rgba 127 127 127 0.14))
    :overlay (rounded-rectangle :radius 8 :stroke (rgba 255 255 255 0.10) :stroke-width 1)))

(def (pr-state-count state prs)
  (count (filter (fn (pr) (= (get pr :state) state)) prs)))

(def (status-dot item)
  (hstack :spacing 5
    (circle :fill (if (get item :color) (hex (get item :color)) (color :green)) :width 7 :height 7)
    (text (str (upper (get item :label)) " " (get item :value))
      :font (font :size 9 :weight semibold :design monospaced)
      :line-limit 1
      :truncation tail)))

(def (port-link port)
  (button
    (hstack :spacing 4
      (image :system "link" :font (font :size 8 :weight bold))
      (text (str port) :font (font :size 10 :weight bold :design monospaced)))
    :action (open-url (str "http://localhost:" port))
    :foreground (color :white)
    :padding (edges :horizontal 6 :vertical 3)
    :background (rgba 10 132 255 0.82)
    :corner-radius 7))

(def (pr-link pr)
  (button
    (hstack :spacing 4
      (image :system (if (get pr :stale) "clock.badge.exclamationmark" "arrow.triangle.pull")
        :font (font :size 9 :weight bold))
      (text (str "#" (get pr :number))
        :font (font :size 10 :weight bold :design monospaced)))
    :action (open-url (get pr :url))
    :foreground (cond
      ((= (get pr :state) "merged") (color :purple))
      ((= (get pr :state) "closed") (color :red))
      ((get pr :draft) (color :gray))
      (else (color :green)))
    :padding (edges :horizontal 5 :vertical 3)
    :background (rgba 127 127 127 0.12)
    :corner-radius 7))

(def (render-row ws)
  (vstack :spacing 7 :max-width infinity :frame-align leading
    (hstack :spacing 6
      (zstack
        (circle :fill (accent ws) :width 18 :height 18 :opacity 0.24)
        (circle :stroke (accent ws) :stroke-width 1 :width 18 :height 18)
        (circle :fill (accent ws) :width 6 :height 6))
      (vstack :spacing 1 :frame-align leading :max-width infinity
        (text (upper (get ws :title))
          :font (font :size 11 :weight black :design monospaced)
          :line-limit 1
          :truncation tail)
        (when (get ws :message)
          (text (get ws :message)
            :font (font :size 10)
            :foreground (muted ws)
            :line-limit 1
            :truncation tail)))
      (when (> (get ws :unread) 0)
        (metric "ALERT" (str (get ws :unread)) (color :red))))
    (hstack :spacing 5
      (metric "PRS" (str (count (get ws :pull-requests))) (color :purple))
      (metric "OPEN" (str (pr-state-count "open" (get ws :pull-requests))) (color :green))
      (metric "PORTS" (str (count (get ws :ports))) (color :blue)))
    (when (or (get ws :branch) (get ws :remote))
      (hstack :spacing 6
        (when (get ws :branch)
          (label :system "arrow.triangle.branch" :text (get ws :branch)
            :font (font :size 10 :weight semibold :design monospaced)
            :foreground (muted ws)
            :line-limit 1
            :truncation middle))
        (when (get ws :remote)
          (label :system "antenna.radiowaves.left.and.right" :text (get ws :remote)
            :font (font :size 10 :weight semibold :design monospaced)
            :foreground (color :green)
            :line-limit 1))))
    (when (not (empty? (get ws :status)))
      (vstack :spacing 2 :max-width infinity :frame-align leading
        (map status-dot (get ws :status))))
    (when (not (empty? (get ws :ports)))
      (hstack :spacing 4 (map port-link (get ws :ports))))
    (when (not (empty? (get ws :pull-requests)))
      (hstack :spacing 4 (map pr-link (get ws :pull-requests))))
    (when (get ws :progress)
      (progress-view :value (get ws :progress) :total 1 :tint (accent ws)))))
