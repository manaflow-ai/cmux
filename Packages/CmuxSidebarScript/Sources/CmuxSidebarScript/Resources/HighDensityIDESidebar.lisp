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

(def (workspace-cell ws)
  (button
    (render-row ws)
    :action (select-workspace ws)
    :padding (edges :horizontal 6 :vertical 5)
    :background (rgba 127 127 127 0.08)
    :overlay (rectangle :stroke (if (get ws :active) (color :blue) (rgba 127 127 127 0.20)) :stroke-width 1)
    :max-width infinity
    :frame-align leading))

(def (render-sidebar sidebar)
  (vstack :spacing 6 :max-width infinity :frame-align leading
    (hstack :spacing 6
      (text "CMUX::SIDEBAR"
        :font (font :size 11 :weight black :design monospaced))
      (spacer)
      (text (str (get sidebar :workspace-count) " WS")
        :font (font :size 9 :weight black :design monospaced)
        :foreground (color :secondary)))
    (grid :columns 1 :spacing 5
      (map workspace-cell (get sidebar :workspaces)))
    (button
      (text "+ NEW"
        :font (font :size 10 :weight black :design monospaced)
        :foreground (color :blue)
        :max-width infinity
        :frame-align center
        :padding (edges :vertical 6)
        :border (rgba 127 127 127 0.3)
        :border-width 1)
      :action (new-workspace :title "Scratch"))
    :padding (edges :horizontal 8 :vertical 10)))
