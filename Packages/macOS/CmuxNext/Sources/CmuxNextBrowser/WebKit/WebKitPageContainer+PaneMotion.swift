import AppKit
import CmuxNextDesign

/// A WebKit page follows its pane in every frame of a key resize (Lawrence 2026-11-05: "we need to try to resize webviews
/// (both chrome and webkit) more often so it is smoother"). It never holds: the browser chrome follows the pane's content
/// area (``BrowserChromeView`` as ``PaneMotionHoldFollowing``), and in each motion frame's layout pass Auto Layout gives this
/// container the chrome's page area, which the web view takes at once through autoresizing (an attached Web Inspector
/// re-places both, as at rest). That page area is the one per-frame size source both engines use (FRAME OWNER S5 for
/// Chromium): neither computes its own size or reads the hold's edges, both take only the newest frame per display frame,
/// neither waits for the page's frame and neither skips a frame. A divider drag needs nothing here: no hold, the same
/// layout pass.
///
/// WebKit draws the new size some frames after the web view takes it; until then the web view's own background shows in
/// the gap, in the page's color (`WebKitTab+ResizeBackdrop`), read again when a key resize starts.
extension WebKitPageContainer: BrowserPagePaneMotionHolding {
    var holdsPageInPaneMotion: Bool { window != nil }

    func holdPage(for hold: PaneMotionHold?) {
        guard hold != nil else { return }
        onPaneMotion?()
    }
}
