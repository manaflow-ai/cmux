public import AppKit

/// A toast host that a window's ``CmuxToastAvoidance`` link reaches when an avoided view in that
/// window changes (``CmuxToastOverlayHost`` in the app; a counting spy in tests).
@MainActor
public protocol CmuxToastReanchoring: AnyObject {
    /// Moves this host's toasts in `window` clear of that window's avoided views.
    func reanchor(in window: NSWindow)
    /// Tells `view` (one view that reserves room in `window`) where this host's toasts rest there, at once.
    func settled(in window: NSWindow, only view: any CmuxToastReserving)
}

extension CmuxToastReanchoring {
    /// A host with no toasts of its own to report (a test spy) tells the view nothing.
    public func settled(in window: NSWindow, only view: any CmuxToastReserving) {}
}
