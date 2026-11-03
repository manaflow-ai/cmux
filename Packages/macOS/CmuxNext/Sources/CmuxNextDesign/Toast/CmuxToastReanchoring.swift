import AppKit

/// A toast host that a window's ``CmuxToastAvoidance`` link reaches when an avoided view in that
/// window changes (``CmuxToastOverlayHost`` in the app; a counting spy in tests).
@MainActor
protocol CmuxToastReanchoring: AnyObject {
    /// Moves this host's toasts in `window` clear of that window's avoided views.
    func reanchor(in window: NSWindow)
}
