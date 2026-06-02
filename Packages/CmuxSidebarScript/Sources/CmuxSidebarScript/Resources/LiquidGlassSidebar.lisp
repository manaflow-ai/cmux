;; Layered glass poster. Uses z-stacks, masks, scale, and translucent geometry
;; so it does not share the standard sidebar-row skeleton.

(def (accent ws)
  (if (get ws :color) (hex (get ws :color)) (rgba 10 132 255 1)))

(def (render-row ws)
  (zstack :alignment bottom-leading :max-width infinity :height 88
    (rounded-rectangle :radius 14
      :fill (gradient (rgba 10 132 255 0.30) (rgba 175 82 222 0.18) :direction diagonal)
      :height 84
      :max-width infinity)
    (circle :fill (accent ws) :width 74 :height 74 :opacity 0.18
      :offset (list 82 -16)
      :blur 1.5)
    (circle :fill (color :white) :width 36 :height 36 :opacity 0.12
      :offset (list -74 24)
      :scale 1.35)
    (vstack :spacing 5 :max-width infinity :frame-align leading
      (hstack :spacing 6
        (zstack
          (circle :fill (rgba 255 255 255 0.20) :width 28 :height 28)
          (image :system (if (get ws :active) "sparkles" "rectangle.3.group")
            :font (font :size 13 :weight black)
            :foreground (color :white)))
        (text (get ws :title)
          :font (font :size 14 :weight black)
          :foreground (color :white)
          :line-limit 2)
        (spacer))
      (hstack :spacing 5
        (when (get ws :branch)
          (text (get ws :branch)
            :font (font :size 10 :weight semibold :design monospaced)
            :foreground (color :white)
            :padding (edges :horizontal 7 :vertical 3)
            :background (rgba 0 0 0 0.22)
            :corner-radius 9))
        (when (> (get ws :unread) 0)
          (text (str (get ws :unread) " alerts")
            :font (font :size 10 :weight semibold)
            :foreground (color :white)
            :padding (edges :horizontal 7 :vertical 3)
            :background (rgba 255 59 48 0.82)
            :corner-radius 9)))
      (when (get ws :progress)
        (progress-view :value (get ws :progress) :total 1 :tint (color :white))))
    :padding (edges :horizontal 8 :vertical 8)
    :mask (rounded-rectangle :radius 14 :fill (color :white) :height 84 :max-width infinity)))

(def (poster ws)
  (button
    (render-row ws)
    :action (select-workspace ws)
    :max-width infinity
    :frame-align leading))

(def (render-sidebar sidebar)
  (zstack :alignment top-leading :max-width infinity
    (circle :fill (rgba 10 132 255 0.14) :width 180 :height 180 :offset (list 70 -60) :blur 8)
    (circle :fill (rgba 175 82 222 0.12) :width 150 :height 150 :offset (list -60 160) :blur 8)
    (vstack :spacing 10 :max-width infinity :frame-align leading
      (text "Liquid Spaces"
        :font (font :size 18 :weight black)
        :foreground (color :primary))
      (map poster (get sidebar :workspaces))
      (button
        (text "Create a new glass workspace"
          :font (font :size 12 :weight semibold)
          :foreground (color :white)
          :padding (edges :horizontal 10 :vertical 8)
          :background (gradient (rgba 10 132 255 0.8) (rgba 175 82 222 0.72) :direction horizontal)
          :corner-radius 12)
        :action (new-workspace :title "Glass Workspace"))
      :padding (edges :horizontal 9 :vertical 11))))
