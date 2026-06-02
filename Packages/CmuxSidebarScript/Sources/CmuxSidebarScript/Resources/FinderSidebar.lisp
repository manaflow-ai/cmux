;; Nested Finder tree. Uses the row as a miniature filesystem navigator instead
;; of a flat workspace card.

(def (muted ws)
  (if (get ws :dark-mode) (rgba 235 235 245 0.55) (rgba 60 60 67 0.55)))

(def (path-parts ws)
  (if (get ws :directory)
      (split (replace (replace (get ws :directory) "~/" "home/") " " "-") "/")
      (list "workspace" (get ws :title))))

(def (tree-line depth label system tint selected)
  (hstack :spacing 5
    (when (> depth 0)
      (rectangle :fill (rgba 127 127 127 0.25) :width 1 :height 18
        :padding (edges :leading (+ 6 (* (- depth 1) 12)))))
    (image :system system
      :font (font :size 12 :weight medium)
      :foreground tint
      :frame-align center
      :width 16)
    (text label
      :font (font :size 12 :weight (if selected semibold regular))
      :line-limit 1
      :truncation tail)
    (spacer)
    :padding (edges :leading (* depth 12) :trailing 4 :vertical 2)
    :background (if selected (rgba 10 132 255 0.18) (color :clear))
    :corner-radius 5))

(def (path-line index part ws)
  (let ((last (= index (- (count (path-parts ws)) 1))))
    (tree-line index part
      (cond
        ((= index 0) "house.fill")
        (last "folder.fill")
        (else "folder"))
      (if last (color :blue) (muted ws))
      last)))

(def (pr-leaf pr)
  (tree-line 2
    (str "#" (get pr :number) " " (get pr :state))
    (if (get pr :stale) "clock.badge.exclamationmark" "arrow.triangle.pull")
    (cond
      ((= (get pr :state) "merged") (color :purple))
      ((= (get pr :state) "closed") (color :red))
      (else (color :green)))
    false))

(def (port-leaf port)
  (button
    (tree-line 2 (str "localhost:" port) "network" (color :blue) false)
    :action (open-url (str "http://localhost:" port))))

(def (render-row ws)
  (vstack :spacing 2 :max-width infinity :frame-align leading
    (hstack :spacing 6
      (image :system "sidebar.left" :font (font :size 12 :weight semibold) :foreground (color :blue))
      (text (get ws :title)
        :font (font :size 12 :weight semibold)
        :line-limit 1
        :truncation tail)
      (spacer)
      (when (> (get ws :unread) 0)
        (text (str (get ws :unread))
          :font (font :size 10 :weight bold :monospaced-digit true)
          :foreground (color :red))))
    (map-indexed (fn (index part) (path-line index part ws)) (path-parts ws))
    (when (get ws :branch)
      (tree-line 1 (get ws :branch) "arrow.triangle.branch" (color :green) false))
    (map pr-leaf (get ws :pull-requests))
    (map port-leaf (get ws :ports))))
