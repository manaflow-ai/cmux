public import AppKit
import ObjectiveC

/// One window's link from its avoided views (``CmuxToastAvoiding``) to the toast hosts that
/// show toasts in it.
///
/// It replaces the app-wide `cmuxToastAvoidanceDidChange` notice, which woke every toast host
/// for every window when one composer moved. Each window holds its own link (an associated
/// object), so no process-wide instance exists. A host registers itself, weakly, when it shows
/// a toast in the window; ``avoidanceChanged(in:)`` reaches only the hosts registered there, and
/// only that window's toasts move. A window that never showed a toast does no work.
///
/// ```swift
/// if let window { CmuxToastAvoidance.avoidanceChanged(in: window) }
/// ```
@MainActor
public final class CmuxToastAvoidance {
    /// The hosts that showed toasts in the window; the window keeps neither them nor their toasts
    /// alive.
    private let hosts = NSHashTable<CmuxToastOverlayHost>.weakObjects()

    private static var key: UInt8 = 0

    private init() {}

    /// `window`'s link if a host ever showed a toast there (never makes one).
    private static func existing(in window: NSWindow) -> CmuxToastAvoidance? {
        objc_getAssociatedObject(window, &key) as? CmuxToastAvoidance
    }

    /// Adds `host` to the hosts that move `window`'s toasts when an avoided view there changes.
    static func register(_ host: CmuxToastOverlayHost, in window: NSWindow) {
        if let link = existing(in: window) {
            link.hosts.add(host)
            return
        }
        let link = CmuxToastAvoidance()
        link.hosts.add(host)
        objc_setAssociatedObject(window, &key, link, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// An avoided view in `window` changed its rect: each host registered in the window moves
    /// that window's shown toasts clear of it on the next main-actor turn (after the layout pass
    /// that called this), sliding from where they are drawn.
    ///
    /// - Parameter window: The window of the view whose ``CmuxToastAvoiding/toastAvoidanceRect``
    ///   changed.
    /// - Returns: The pending move, for callers that must wait for it (tests); nil when no host
    ///   shows toasts in `window`.
    @discardableResult
    public static func avoidanceChanged(in window: NSWindow) -> Task<Void, Never>? {
        guard let link = existing(in: window), link.hosts.anyObject != nil else { return nil }
        // task-owner: one hop past the caller's layout pass; moves this window's toasts once
        return Task { [weak link, weak window] in
            guard let window, let link else { return }
            for host in link.hosts.allObjects { host.reanchor(in: window) }
        }
    }
}
