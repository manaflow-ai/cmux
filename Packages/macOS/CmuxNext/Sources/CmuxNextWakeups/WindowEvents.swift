public import AppKit
import ObjectiveC

/// One window's notifications (`NSWindow.didBecomeKeyNotification`, `didChangeOcclusionStateNotification`,
/// `willCloseNotification`, ...) for every view and controller in it: one NotificationCenter
/// observer per name, made on the first subscription and removed with the last, fanned out to the
/// subscribers whose node is on screen (architecture-refactor-DESIGN.md row B, A4;
/// plans/cmux-next/chrome-parity/p06-scheduler.md, 021).
///
/// Before it, each view observed its window itself: a Cmd-Tab or an occlusion change cost
/// O(views in the window) handler runs, hidden views included. Chromium observes an NSWindow once,
/// in its delegate (`components/remote_cocoa/app_shim/views_nswindow_delegate.mm`), and fans out
/// through the widget's observer list (`ui/views/widget/widget.cc`); a hidden page reads its state
/// when it shows (`content::WebContentsImpl::WasShown`), it is not told every change.
///
/// ```swift
/// // The view keeps the token; releasing it (or `cancel()`) ends the subscription.
/// keyWatch = WindowEvents.of(window).subscribe(NSWindow.didBecomeKeyNotification, node: paneNode,
///                                              delivery: .whenVisible, owner: "StatusIndicator") { [weak self] _ in
///     self?.updateKeyAppearance()
/// }
/// ```
///
/// A ``EventDelivery/whenVisible`` subscriber whose node is hidden or occluded gets no call per
/// post; it gets one ``EventCall/missed`` call when the node next shows, and reads the current
/// state then.
@MainActor public final class WindowEvents {
    private let fanOut: NotificationFanOut

    private static var associationKey: UInt8 = 0

    /// Observes `window`'s notifications on `center`. The app uses ``of(_:center:)``, which keeps
    /// one per window; tests make their own.
    ///
    /// - Parameters:
    ///   - window: The window whose notifications are observed (held weakly).
    ///   - center: Where the window posts (tests pass their own).
    public init(window: NSWindow, center: NotificationCenter = .default) {
        fanOut = NotificationFanOut(object: window, center: center)
    }

    /// `window`'s events, made on first use and kept alive by the window. A later call returns the
    /// same instance and ignores `center`.
    public static func of(_ window: NSWindow, center: NotificationCenter = .default) -> WindowEvents {
        if let existing = objc_getAssociatedObject(window, &associationKey) as? WindowEvents { return existing }
        let events = WindowEvents(window: window, center: center)
        objc_setAssociatedObject(window, &associationKey, events, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return events
    }

    /// Calls `handler` for each post of `name` by the window, by `node`'s visibility.
    ///
    /// - Parameters:
    ///   - name: The window notification.
    ///   - node: The subscriber's node (held weakly; a released node gets no more ``EventDelivery/whenVisible`` calls).
    ///   - delivery: ``EventDelivery/whenVisible`` for view work, ``EventDelivery/always`` for work
    ///     a person waits for while the view is hidden.
    ///   - owner: The subscriber's name for diagnostics.
    ///   - handler: Main-actor work; ``EventCall/missed`` when it runs on show for posts it missed.
    /// - Returns: The subscription; keep it, releasing it ends the subscription.
    public func subscribe(_ name: Notification.Name, node: VisibilityNode, delivery: EventDelivery, owner: String,
                          _ handler: @escaping @MainActor (EventCall) -> Void) -> EventSubscription {
        fanOut.subscribe(name, node: node, delivery: delivery, owner: owner, handler)
    }

    /// Calls `handler` for every post of `name` by the window: for an owner with no node that
    /// decides for the whole window (a key tracker, the frame scheduler).
    public func subscribe(_ name: Notification.Name, owner: String,
                          _ handler: @escaping @MainActor () -> Void) -> EventSubscription {
        fanOut.subscribe(name, node: nil, delivery: .always, owner: owner) { _ in handler() }
    }

    /// Whether `key` (the key window, nil when none) is `window` or a window it owns, through
    /// `owner` (a window's parent or sheet parent): its own Chromium page window, popup, palette or
    /// sheet. The one family walk the key trackers and the resign-key capture share.
    nonisolated public static func family<W: AnyObject>(of window: W, holds key: W?, owner: (W) -> W?) -> Bool {
        var next = key
        // Window chains are a few levels deep; the bound guards a cycle.
        for _ in 0..<32 {
            guard let current = next else { return false }
            if current === window { return true }
            next = owner(current)
        }
        return false
    }

    /// Whether a NotificationCenter observer for `name` exists (one while it has a subscriber).
    package func isObserving(_ name: Notification.Name) -> Bool { fanOut.isObserving(name) }

    /// How many subscriptions to `name` are live.
    package func subscriberCount(_ name: Notification.Name) -> Int { fanOut.subscriberCount(name) }

    /// How many posts of `name` the center delivered here: one per post, however many subscribers.
    package func deliveries(_ name: Notification.Name) -> Int { fanOut.deliveries(name) }

    /// How many times it handed a node deferred work: once per node that gained a missed
    /// subscriber, however many posts and subscribers.
    package var deferredWork: Int { fanOut.deferredWork }
}
