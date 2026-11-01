import AppKit
import CmuxNextDesign
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
    func wireContentAreaMotion() {
        sidebar.onWidthMotionStart = { [weak self] from, to in self?.holdContentThroughSlide(from: from, to: to) }
        sidebar.onWidthMotionChange = { [weak self] animating in
            guard !animating, let self else { return }
            // Flush layout at the landed width before content hears the motion ended: the
            // workspace sizes its layout in `layout()` (an empty autoresizing mask), so the subtree is
            // laid out now, or a terminal would settle at the held width and report a stale grid.
            contentHost.contentHold = nil
            layoutSubtreeIfNeeded()
            notifyPaneMotionSettled()
        }
    }

    /// Opt-in (`sidebar.slideHoldsContent`): sizes content once for the whole slide (GPU audit
    /// 2026-10-21); the default follows the card each frame (#29894). The
    /// sidebar's width animation moves the card's edge on every frame, and a card that resized its
    /// content with it laid out every pane, terminal and Chromium page at a new width per frame. The
    /// content takes its landing width now, pinned to the card's far edge (which does not move), and
    /// stays still: a hide uncovers it, a show narrows it at once. Riding the moving edge at the widest
    /// width laid it out away from where it lands and jumped there (Leo, 2026-11-01: "THE ENTIRE
    /// OTHER PART OF THE APP SHIFT LAYOUT FOR NO REASON AND SNAP BACK"). A turnaround lays out again.
    /// The rail style opens over the content (`WindowRootView+SidebarRail`), which never resizes:
    /// nothing to hold. The card clips the held content while it holds it, square or rounded.
    private func holdContentThroughSlide(from: CGFloat, to: CGFloat) {
        let landing = contentHost.bounds.width + from - to
        guard SidebarTunables.slideHoldsContent.value, sidebar.model.style != .rail, landing > 0 else {
            contentHost.contentHold = nil
            return
        }
        contentHost.contentHold = MainPaneCardView.ContentHold(width: landing, pinsTrailingEdge: sidebarSide == .left)
    }
}
