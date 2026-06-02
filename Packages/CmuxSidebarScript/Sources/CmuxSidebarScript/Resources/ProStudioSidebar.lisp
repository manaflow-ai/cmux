;; Timeline rail. A production-console row with vertical stages and status chips.

(def (muted ws)
  (if (get ws :dark-mode) (rgba 235 235 245 0.52) (rgba 60 60 67 0.55)))

(def (stage label value system tint last)
  (hstack :spacing 7
    (vstack :spacing 0
      (zstack
        (circle :fill tint :width 16 :height 16 :opacity 0.22)
        (image :system system :font (font :size 8 :weight black) :foreground tint))
      (unless last
        (rectangle :fill (rgba 127 127 127 0.22) :width 1 :height 13)))
    (vstack :spacing 1 :frame-align leading :max-width infinity
      (text label
        :font (font :size 9 :weight black :design monospaced)
        :foreground tint
        :line-limit 1)
      (text value
        :font (font :size 11 :weight medium)
        :line-limit 1
        :truncation tail))))

(def (render-row ws)
  (vstack :spacing 5 :max-width infinity :frame-align leading
    (hstack :spacing 6
      (text (get ws :title)
        :font (font :size 13 :weight bold)
        :line-limit 1
        :truncation tail)
      (spacer)
      (when (get ws :progress)
        (text (str (round (* 100 (get ws :progress))) "%")
          :font (font :size 10 :weight black :design monospaced)
          :foreground (color :orange))))
    (stage "WORKTREE" (if (get ws :directory) (get ws :directory) "not opened") "folder.fill" (color :blue) false)
    (stage "BRANCH" (if (get ws :branch) (get ws :branch) "detached") "arrow.triangle.branch" (color :green) false)
    (stage "REVIEW" (str (count (get ws :pull-requests)) " pull requests") "arrow.triangle.pull" (color :purple) false)
    (stage "RUNTIME" (if (empty? (get ws :ports)) "no ports" (str "ports " (join "," (get ws :ports)))) "play.circle.fill" (color :orange) true)))

(def (timeline-card ws)
  (button
    (render-row ws)
    :action (select-workspace ws)
    :padding (edges :horizontal 8 :vertical 7)
    :background (rounded-rectangle :radius 8 :fill (rgba 127 127 127 0.10))
    :overlay (rounded-rectangle :radius 8 :stroke (if (get ws :active) (color :orange) (rgba 127 127 127 0.18)) :stroke-width 1)
    :max-width infinity
    :frame-align leading))

(def (render-sidebar sidebar)
  (vstack :spacing 7 :max-width infinity :frame-align leading
    (hstack :spacing 6
      (image :system "slider.horizontal.3" :font (font :size 14 :weight bold) :foreground (color :orange))
      (text "Production Queue" :font (font :size 14 :weight bold))
      (spacer))
    (map timeline-card (get sidebar :workspaces))
    (button
      (stage "CREATE" "new blank workspace" "plus" (color :orange) true)
      :action (new-workspace :title "Production Scratch"))
    :padding (edges :horizontal 8 :vertical 10)))
