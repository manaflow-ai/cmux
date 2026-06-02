;; Dense IDE matrix. The row becomes a compact telemetry table instead of a
;; title/detail stack.

(def (muted ws)
  (if (get ws :dark-mode) (rgba 235 235 245 0.48) (rgba 60 60 67 0.55)))

(def (metric label value tint)
  (vstack :spacing 1 :frame-align leading
    (text label
      :font (font :size 8 :weight bold :design monospaced)
      :foreground (color :secondary)
      :line-limit 1)
    (text value
      :font (font :size 12 :weight black :design monospaced)
      :foreground tint
      :line-limit 1
      :minimum-scale-factor 0.7)
    :padding (edges :horizontal 5 :vertical 4)
    :background (rgba 127 127 127 0.11)
    :overlay (rectangle :stroke (rgba 127 127 127 0.22) :stroke-width 1)))

(def (open-prs prs)
  (count (filter (fn (pr) (= (get pr :state) "open")) prs)))

(def (render-row ws)
  (vstack :spacing 4 :max-width infinity :frame-align leading
    (hstack :spacing 4
      (text (substring (upper (get ws :title)) 0 24)
        :font (font :size 10 :weight black :design monospaced)
        :line-limit 1)
      (spacer)
      (text (if (get ws :active) "ACTIVE" "IDLE")
        :font (font :size 8 :weight black :design monospaced)
        :foreground (if (get ws :active) (color :green) (muted ws))))
    (grid :columns 4 :spacing 3
      (metric "PR" (str (open-prs (get ws :pull-requests))) (color :purple))
      (metric "PORT" (str (count (get ws :ports))) (color :blue))
      (metric "MSG" (str (get ws :unread)) (color :red))
      (metric "RUN" (if (get ws :progress) (str (round (* 100 (get ws :progress))) "%") "--") (color :green)))
    (hstack :spacing 4
      (when (get ws :branch)
        (text (get ws :branch)
          :font (font :size 9 :design monospaced)
          :foreground (muted ws)
          :line-limit 1
          :truncation middle))
      (spacer)
      (when (not (empty? (get ws :ports)))
        (text (join "," (get ws :ports))
          :font (font :size 9 :weight medium :design monospaced)
          :foreground (color :blue))))))
