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

(def (workspace-expanded-key ws)
  (str "finder.workspace." (get ws :id)))

(def (expanded? state key)
  (= (get state key "false") "true"))

(def (disclosure ws state)
  (button
    (image :system (if (expanded? state (workspace-expanded-key ws)) "chevron.down" "chevron.right")
      :font (font :size 9 :weight bold)
      :foreground (muted ws)
      :width 13
      :frame-align center)
    :action (toggle-sidebar-state (workspace-expanded-key ws))))

(def (file-row file ws)
  (button
    (hstack :spacing 5
      (image :system (if (get file :directory) "folder.fill" "doc")
        :font (font :size 11 :weight medium)
        :foreground (if (get file :directory) (color :blue) (muted ws))
        :width 16
        :frame-align center)
      (text (get file :name)
        :font (font :size 11)
        :line-limit 1
        :truncation tail)
      (spacer)
      :padding (edges :leading 34 :trailing 4 :vertical 2)
      :corner-radius 5)
    :action (open-workspace file)
    :max-width infinity
    :frame-align leading))

(def (workspace-files ws state)
  (when (expanded? state (workspace-expanded-key ws))
    (vstack :spacing 1 :max-width infinity :frame-align leading
      (map (fn (file) (file-row file ws)) (get ws :files)))))

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

(def (workspace-node ws state)
  (vstack :spacing 1 :max-width infinity :frame-align leading
    (hstack :spacing 0
      (disclosure ws state)
      (button
        (render-row ws)
        :action (select-workspace ws)
        :max-width infinity
        :frame-align leading))
    (workspace-files ws state)))

(def (render-sidebar sidebar)
  (vstack :spacing 5 :max-width infinity :frame-align leading
    (hstack :spacing 6
      (image :system "folder.fill" :font (font :size 13 :weight semibold) :foreground (color :blue))
      (text "Workspaces"
        :font (font :size 13 :weight bold))
      (spacer)
      (text (str (get sidebar :workspace-count))
        :font (font :size 10 :weight bold :monospaced-digit true)
        :foreground (color :secondary)))
    (map (fn (ws) (workspace-node ws (get sidebar :state))) (get sidebar :workspaces))
    (button
      (tree-line 0 "New Workspace" "plus" (color :blue) false)
      :action (new-workspace :title "Scratch"))
    :padding (edges :horizontal 8 :vertical 10)))
