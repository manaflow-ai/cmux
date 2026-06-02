;; cmux default sidebar row.
;;
;; `render-row` receives one workspace record and returns a view. Copy this file
;; to ~/.config/cmux/sidebar.lisp and edit it to customize the sidebar. Anything
;; you can express in SwiftUI you can build here: stacks, text, images, shapes,
;; colors, fonts, and the usual view modifiers as :keyword options.
;;
;; The workspace record fields: :title :detail :branch :directory :directories
;; :pull-requests (list of {:number :state :url :title :draft :stale})
;; :ports (list) :unread :pinned :active :selected :color :dark-mode :message
;; :progress :remote :status (list of {:label :value :color}).

(def (secondary ws)
  (if (get ws :dark-mode)
      (rgba 235 235 245 0.6)
      (rgba 60 60 67 0.6)))

(def (title-color ws)
  (cond
    ((get ws :active) (if (get ws :dark-mode) (color :white) (color :black)))
    (else (color :primary))))

(def (pr-color pr)
  (cond
    ((= (get pr :state) "merged") (color :purple))
    ((= (get pr :state) "closed") (color :red))
    ((get pr :draft) (color :gray))
    (else (color :green))))

(def (unread-badge ws)
  (when (> (get ws :unread) 0)
    (text (str (get ws :unread))
      :font (font :size 10 :weight bold :monospaced-digit true)
      :foreground (color :white)
      :padding (edges :horizontal 5 :vertical 1)
      :background (color :red)
      :corner-radius 8)))

(def (header ws)
  (hstack :spacing 5
    (when (get ws :pinned)
      (image :system "pin.fill"
        :font (font :size 9)
        :foreground (secondary ws)))
    (text (get ws :title)
      :font (font :size 13 :weight semibold)
      :foreground (title-color ws)
      :line-limit 1
      :truncation tail)
    (spacer)
    (unread-badge ws)))

(def (branch-line ws)
  (when (get ws :branch)
    (hstack :spacing 4
      (image :system "arrow.triangle.branch"
        :font (font :size 10)
        :foreground (secondary ws))
      (text (get ws :branch)
        :font (font :size 10 :design monospaced)
        :foreground (secondary ws)
        :line-limit 1
        :truncation middle))))

(def (directory-line ws)
  (when (get ws :directory)
    (text (get ws :directory)
      :font (font :size 10)
      :foreground (secondary ws)
      :line-limit 1
      :truncation head)))

(def (pr-row pr)
  (hstack :spacing 4
    (image :system "circle.fill"
      :font (font :size 7)
      :foreground (pr-color pr))
    (text (str "#" (get pr :number))
      :font (font :size 10 :weight medium :design monospaced)
      :foreground (pr-color pr)
      :line-limit 1)
    (when (get pr :stale)
      (image :system "clock.badge.exclamationmark"
        :font (font :size 9)
        :foreground (color :orange)))
    :on-tap (open-url (get pr :url))))

(def (port-chip port)
  (text (str port)
    :font (font :size 9 :design monospaced)
    :foreground (color :white)
    :padding (edges :horizontal 4 :vertical 1)
    :background (rgba 10 132 255 0.85)
    :corner-radius 4
    :on-tap (open-url (str "http://localhost:" port))))

(def (ports-line ws)
  (when (not (empty? (get ws :ports)))
    (hstack :spacing 4
      (map port-chip (get ws :ports)))))

(def (progress-bar ws)
  (when (get ws :progress)
    (progress-view :value (get ws :progress) :total 1
      :tint (color :accent))))

;; cmux draws the row's selection background, padding, and chrome. The script
;; owns the row's content: layout, typography, badges, and colors.
(def (render-row ws)
  (vstack :spacing 4 :max-width infinity :frame-align leading
    (header ws)
    (when (get ws :detail)
      (text (get ws :detail)
        :font (font :size 11)
        :foreground (secondary ws)
        :line-limit 2))
    (branch-line ws)
    (directory-line ws)
    (map pr-row (get ws :pull-requests))
    (ports-line ws)
    (progress-bar ws)))
