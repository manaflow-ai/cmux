import AppKit
import CmuxNextDesign

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
        sidebar.onWidthMotionChange = { [weak self] animating in
            guard !animating else { return }
            self?.notifyPaneMotionSettled()
        }
    }
}
