;; Ops dashboard. A tile board with alerts, service links, PR state, and status.

(def (accent ws)
  (if (get ws :active) (color :green) (if (get ws :color) (hex (get ws :color)) (color :accent))))

(def (tile label value system tint)
  (vstack :spacing 3 :frame-align leading
    (hstack :spacing 4
      (image :system system :font (font :size 9 :weight black) :foreground tint)
      (text label
        :font (font :size 8 :weight black :design monospaced)
        :foreground (color :secondary)))
    (text value
      :font (font :size 13 :weight black :design monospaced)
      :foreground tint
      :line-limit 1)
    :padding (edges :horizontal 7 :vertical 6)
    :background (rounded-rectangle :radius 9 :fill (rgba 127 127 127 0.13))
    :overlay (rounded-rectangle :radius 9 :stroke (rgba 255 255 255 0.10) :stroke-width 1)))

(def (status-tile item)
  (tile (upper (get item :label)) (get item :value) "circle.fill"
    (if (get item :color) (hex (get item :color)) (color :green))))

(def (open-prs prs)
  (count (filter (fn (pr) (= (get pr :state) "open")) prs)))

(def (port-button port)
  (button
    (tile "HTTP" (str port) "link" (color :blue))
    :action (open-url (str "http://localhost:" port))))

(def (render-row ws)
  (vstack :spacing 6 :max-width infinity :frame-align leading
    (hstack :spacing 6
      (circle :fill (accent ws) :width 9 :height 9)
      (text (upper (get ws :title))
        :font (font :size 11 :weight black :design monospaced)
        :line-limit 1
        :truncation tail)
      (spacer)
      (when (> (get ws :unread) 0)
        (text "ALERT"
          :font (font :size 8 :weight black :design monospaced)
          :foreground (color :white)
          :padding (edges :horizontal 6 :vertical 2)
          :background (color :red)
          :corner-radius 6)))
    (grid :columns 3 :spacing 4
      (tile "PRS" (str (open-prs (get ws :pull-requests))) "arrow.triangle.pull" (color :purple))
      (tile "PORTS" (str (count (get ws :ports))) "network" (color :blue))
      (tile "MSG" (str (get ws :unread)) "bell.fill" (color :red))
      (map status-tile (get ws :status))
      (map port-button (get ws :ports)))
    (when (get ws :progress)
      (progress-view :value (get ws :progress) :total 1 :tint (accent ws)))))

(def (ops-card ws)
  (button
    (render-row ws)
    :action (select-workspace ws)
    :padding (edges :horizontal 6 :vertical 6)
    :background (if (get ws :active) (rgba 52 199 89 0.12) (rgba 127 127 127 0.08))
    :overlay (rounded-rectangle :radius 10 :stroke (if (get ws :active) (color :green) (rgba 127 127 127 0.18)) :stroke-width 1)
    :corner-radius 10
    :max-width infinity
    :frame-align leading))

(def (render-sidebar sidebar)
  (vstack :spacing 8 :max-width infinity :frame-align leading
    (grid :columns 3 :spacing 4
      (tile "TOTAL" (str (get sidebar :workspace-count)) "rectangle.stack.fill" (color :blue))
      (tile "MODE" "LISP" "curlybraces" (color :purple))
      (tile "SCOPE" "FULL" "sidebar.left" (color :green)))
    (map ops-card (get sidebar :workspaces))
    (button
      (tile "SPAWN" "NEW" "plus.circle.fill" (color :green))
      :action (new-workspace :title "Agent Ops"))
    :padding (edges :horizontal 8 :vertical 10)))
