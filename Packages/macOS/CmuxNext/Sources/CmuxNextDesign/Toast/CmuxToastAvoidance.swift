public import AppKit
import ObjectiveC

/// One window's link from its avoided views (``CmuxToastAvoiding``) to the toast hosts that
/// show toasts in it.
///
/// It replaces the app-wide `cmuxToastAvoidanceDidChange` notice, which woke every toast host
/// for every window when one composer moved. Each window holds its own link (an associated
/// object), so no process-wide instance exists. A host registers itself, weakly, when it shows
/// a toast in the window and leaves when its last toast there goes; ``avoidanceChanged(in:)``
/// reaches only the hosts that show toasts there, and only that window's toasts move. A window
/// that shows no toast does no work and starts no task.
///
/// This is a window-scoped seam reached through a static lookup on the window, not constructor
/// injection: the poster (`HomeNativeTranscriptView`) finds the link through its window.
///
/// ```swift
/// if let window { CmuxToastAvoidance.avoidanceChanged(in: window) }
/// ```
@MainActor
public final class CmuxToastAvoidance {
    /// The hosts that show toasts in the window; the window keeps neither them nor their toasts
    /// alive. Never empty while the link is attached (the last host to leave detaches it).
    private let hosts = NSHashTable<AnyObject>.weakObjects()

    private static var key: UInt8 = 0

    private init() {}

    /// `window`'s link if a host shows a toast there (never makes one).
    private static func existing(in window: NSWindow) -> CmuxToastAvoidance? {
        objc_getAssociatedObject(window, &key) as? CmuxToastAvoidance
    }

    /// Adds `host` to the hosts that move `window`'s toasts when an avoided view there changes.
    public static func register(_ host: any CmuxToastReanchoring, in window: NSWindow) {
        if let link = existing(in: window) {
            link.hosts.add(host)
            return
        }
        let link = CmuxToastAvoidance()
        link.hosts.add(host)
        objc_setAssociatedObject(window, &key, link, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Removes `host` from `window`'s link once it shows no toast there; the last host to leave
    /// detaches the link, so later changes in `window` start no task.
    public static func unregister(_ host: any CmuxToastReanchoring, from window: NSWindow) {
        guard let link = existing(in: window) else { return }
        link.hosts.remove(host)
        if link.hosts.anyObject == nil { objc_setAssociatedObject(window, &key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// `view` came into `window` (a tab shown again, a pane moved): it learns where `window`'s toasts
    /// rest now, at once, or that none shows (it may have left while toasts showed, and they went).
    public static func reservingViewMoved(_ view: any CmuxToastReserving, to window: NSWindow) {
        guard let link = existing(in: window), link.hosts.anyObject != nil else {
            view.toastsSettled(in: nil, duration: 0)
            return
        }
        for case let host as any CmuxToastReanchoring in link.hosts.allObjects { host.settled(in: window, only: view) }
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
            for case let host as any CmuxToastReanchoring in link.hosts.allObjects { host.reanchor(in: window) }
        }
    }

    /// The gap between a toast and the view it avoids.
    public static let avoidanceGap: CGFloat = 8

    /// The lowest bottom edge (window coordinates) a toast of `width`, centered in `bounds`, may
    /// take in `window`: above every avoided rect under it, else `bounds.minY`.
    public static func floor(width: CGFloat, in bounds: NSRect, window: NSWindow) -> CGFloat {
        let band = NSRect(x: bounds.midX - width / 2 - avoidanceGap, y: bounds.minY,
                          width: width + 2 * avoidanceGap, height: bounds.height)
        var floor = bounds.minY
        // Every shown view under the content view, a view before its subviews. An explicit stack,
        // not a recursive local function that captures `floor` (Swift 6.3.3's SendNonSendable pass
        // crashed now and then on such captures in Release).
        var pending: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = pending.popLast() {
            guard !view.isHidden, view.alphaValue > 0.01 else { continue }
            if let avoiding = view as? any CmuxToastAvoiding {
                let rect = avoiding.convert(avoiding.toastAvoidanceRect, to: nil)
                if !rect.isEmpty, rect.intersects(band) { floor = max(floor, rect.maxY + avoidanceGap) }
            }
            pending.append(contentsOf: view.subviews.reversed())
        }
        return floor
    }

    /// Every view under `window`'s content view that reserves room for toasts, hidden ones too
    /// (one hidden while toasts showed still hears that they went).
    public static func reservingViews(in window: NSWindow) -> [any CmuxToastReserving] {
        var found: [any CmuxToastReserving] = []
        var pending: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = pending.popLast() {
            if let reserving = view as? any CmuxToastReserving { found.append(reserving) }
            pending.append(contentsOf: view.subviews)
        }
        return found
    }
}
