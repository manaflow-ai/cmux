public import AppKit

/// One toast as its window's host draws it: the toast and the state the person changed on it.
public nonisolated struct CmuxToastShown: Equatable, Sendable {
    /// The toast's serial, unique for the app's run: a toast shown again under the same id has a new one.
    public var serial: Int
    public var toast: CmuxToast
    /// Details is on (``CmuxToast/Action/revealsDetails``): the whole message and its detail show in the toast.
    public var showsDetails: Bool
    /// Cmd-Z runs this toast's Undo (the window's newest undo toast): its button says so.
    public var showsUndoKey: Bool

    public init(serial: Int, toast: CmuxToast, showsDetails: Bool = false, showsUndoKey: Bool = false) {
        self.serial = serial
        self.toast = toast
        self.showsDetails = showsDetails
        self.showsUndoKey = showsUndoKey
    }
}

/// Draws a window's toasts (the app's native toast views, ``CmuxToastOverlayHost``; a recording host in tests).
///
/// The center owns which toasts show, their order, timers and state; the host only draws them, at the
/// bottom center of the window, newest at the bottom, and reports the person's clicks and pointer back
/// to the center (``CmuxToastCenter/personRanAction(serial:)``, ``CmuxToastCenter/personClosed(serial:)``,
/// ``CmuxToastCenter/pointer(onToast:_:)``), and a closed window (``CmuxToastCenter/windowClosed(_:)``).
@MainActor
public protocol CmuxToastHosting: AnyObject {
    /// `window`'s toasts are now `toasts`, oldest first (empty: none shows). Called once per change
    /// (a show, an end, Details on or off, the undo key moving); the host moves its drawing from what
    /// it shows to this, with no jump.
    func show(_ toasts: [CmuxToastShown], in window: NSWindow, center: CmuxToastCenter)
}

/// Draws nothing: the center's host until the app injects its own (tests, a headless run).
@MainActor
public final class CmuxToastNoHost: CmuxToastHosting {
    public init() {}
    public func show(_ toasts: [CmuxToastShown], in window: NSWindow, center: CmuxToastCenter) {}
}
