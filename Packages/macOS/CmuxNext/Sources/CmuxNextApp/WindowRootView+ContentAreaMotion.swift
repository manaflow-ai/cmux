import AppKit
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSidebar

/// The window's chrome resizing the content area over several frames. Only the
/// sidebar does this today: every frame of its width animation moves the
/// content edge, so Auto Layout resizes every pane beside it even though no
/// pane is on a layout spring of its own. Content whose resize is costly (a
/// terminal's PTY grid and shell redraw) holds it until the landing, exactly as
/// it does inside a pane's own spring (`RestingPlacement`).
extension WindowRootView {
    /// Whether the chrome is resizing the content area now. `ShellWindow`
    /// answers `ContentAreaMotionHosting` from this, and `NSView.isInPaneMotion`
    /// reads it through the window, so it holds for every view in the window.
    var isContentAreaInMotion: Bool { sidebar.isWidthAnimating }

    /// Tells the window's content when the sidebar's motion lands, so what held
    /// a costly resize does it once, now. The whole window and not only the
    /// content host: the motion is window-scoped, so a terminal anywhere in it
    /// held its grid and would otherwise hold it for good.
    ///
    /// Each shown workspace layout also takes the motion as a resize of its content area, as it takes a person's live
    /// resize of the window (`LayoutRootView.contentAreaMotionDidChange(active:)`): its pane views post their frame
    /// notices once at the landing and not in each frame, panes below the window's top row tell their content of their
    /// window-frame move once, and panes scrolled out of the viewport lay out once. The side_close of nightly
    /// f03fe4b38e72 spent 90.8 ms a frame (p50) with 9 chat panes and settled in 348 ms (s9-chat-w10).
    func wireContentAreaMotion() {
        sidebar.onWidthMotionChange = { [weak self] animating in
            guard let self else { return }
            guard !animating else {
                for root in shownLayoutRoots() {
                    contentAreaMotionRoots.add(root)
                    root.contentAreaMotionDidChange(active: true)
                }
                return
            }
            // Flush layout at the landed width before content hears the motion ended: the
            // workspace sizes its layout in `layout()` (an empty autoresizing mask), so the subtree is
            // laid out now, or a terminal would settle at a stale width and report a stale grid.
            layoutSubtreeIfNeeded()
            let roots = contentAreaMotionRoots.allObjects
            contentAreaMotionRoots.removeAllObjects()
            for root in roots { root.contentAreaMotionDidChange(active: false) }
            // The panes it kept out of the viewport at their old size lay out at their final one.
            if !roots.isEmpty { layoutSubtreeIfNeeded() }
            notifyPaneMotionSettled()
        }
    }

    /// The workspace layouts shown in this window (none in a hidden subtree), for one walk at a motion's start.
    private func shownLayoutRoots() -> [LayoutRootView] {
        var roots: [LayoutRootView] = []
        var pending: [NSView] = subviews
        while let view = pending.popLast() {
            guard !view.isHidden, view !== sidebar else { continue }
            if let root = view as? LayoutRootView { roots.append(root); continue }
            pending.append(contentsOf: view.subviews)
        }
        return roots
    }
}
