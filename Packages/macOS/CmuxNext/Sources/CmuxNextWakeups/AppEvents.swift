public import Foundation

/// App-wide notifications (`NSApplication.didBecomeActiveNotification`, any window's
/// `NSWindow.didBecomeKeyNotification`, a setting's change notice) for every subscriber in the
/// app: one NotificationCenter observer per name, made on the first subscription and removed with
/// the last, fanned out to the subscribers whose node is on screen (architecture-refactor-DESIGN.md
/// row B, A4; plans/cmux-next/chrome-parity/p06-scheduler.md, 021). It observes every sender;
/// one window's own notices go through ``WindowEvents``. The composition root makes the app's one
/// instance on `NotificationCenter.default` and injects it (`AppServices.appEvents`); tests make
/// their own on their own center.
///
/// Chromium's app controller observes the NSApp notices once (`chrome/browser/app_controller_mac.mm`)
/// and fans out to its observers, not once per window or view.
///
/// ```swift
/// activeWatch = appEvents.subscribe(NSApplication.didBecomeActiveNotification,
///                                   node: rowNode, delivery: .whenVisible, owner: "SidebarRow") { [weak self] _ in
///     self?.refreshActiveTint()
/// }
/// ```
///
/// A ``EventDelivery/whenVisible`` subscriber whose node is hidden or occluded gets no call per
/// post; it gets one ``EventCall/missed`` call when the node next shows.
@MainActor public final class AppEvents {
    private let fanOut: NotificationFanOut

    /// Observes every sender's notifications on `center` (held weakly). Make one per center and
    /// share it: each instance has its own observers.
    ///
    /// - Parameters:
    ///   - center: Where the notifications are posted.
    ///   - observerLedger: For a system center (NSWorkspace's, the distributed one), whose wakes are process wakeups:
    ///     in Debug and bench builds that ledger's arm census records each observer (one per name, under its first
    ///     subscriber's owner and line) and its first post (startup-queue.py arms). Nil records
    ///     none, as for the app's own center.
    public init(center: NotificationCenter, observerLedger: WakeupLedger? = nil) {
        fanOut = NotificationFanOut(object: nil, center: center, observerLedger: observerLedger)
    }

    /// Calls `handler` for each post of `name`, by `node`'s visibility.
    ///
    /// - Parameters:
    ///   - name: The notification (from any sender).
    ///   - node: The subscriber's node (held weakly; a released node gets no more ``EventDelivery/whenVisible`` calls).
    ///   - delivery: ``EventDelivery/whenVisible`` for view work, ``EventDelivery/always`` for work
    ///     a person waits for while the view is hidden.
    ///   - owner: The subscriber's name for diagnostics.
    ///   - file: The line that subscribed, named by the arm census (leave the default).
    ///   - line: See `file`.
    ///   - handler: Main-actor work; ``EventCall/missed`` when it runs on show for posts it missed.
    /// - Returns: The subscription; keep it, releasing it ends the subscription.
    public func subscribe(_ name: Notification.Name, node: VisibilityNode, delivery: EventDelivery, owner: String,
                          file: StaticString = #fileID, line: UInt = #line,
                          _ handler: @escaping @MainActor (EventCall) -> Void) -> EventSubscription {
        fanOut.subscribe(name, node: node, delivery: delivery, owner: owner, file: file, line: line, handler)
    }

    /// Calls `handler` for every post of `name`: for an owner with no node that decides for a
    /// whole window or the app (a window's key tracker).
    public func subscribe(_ name: Notification.Name, owner: String, file: StaticString = #fileID, line: UInt = #line,
                          _ handler: @escaping @MainActor () -> Void) -> EventSubscription {
        fanOut.subscribe(name, node: nil, delivery: .always, owner: owner, file: file, line: line) { _ in handler() }
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
