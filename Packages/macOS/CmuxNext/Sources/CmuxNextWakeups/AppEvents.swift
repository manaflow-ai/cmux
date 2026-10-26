public import Foundation
import ObjectiveC

/// App-wide notifications (`NSApplication.didBecomeActiveNotification`, any window's
/// `NSWindow.didBecomeKeyNotification`, a setting's change notice) for every subscriber in the
/// app: one NotificationCenter observer per name, made on the first subscription and removed with
/// the last, fanned out to the subscribers whose node is on screen (architecture-refactor-DESIGN.md
/// row B, A4; plans/cmux-next/chrome-parity/p06-scheduler.md, 021). It observes every sender;
/// one window's own notices go through ``WindowEvents``.
///
/// Chromium's app controller observes the NSApp notices once (`chrome/browser/app_controller_mac.mm`)
/// and fans out to its observers, not once per window or view.
///
/// ```swift
/// activeWatch = AppEvents.of(.default).subscribe(NSApplication.didBecomeActiveNotification,
///                                                node: rowNode, delivery: .whenVisible, owner: "SidebarRow") { [weak self] _ in
///     self?.refreshActiveTint()
/// }
/// ```
///
/// A ``EventDelivery/whenVisible`` subscriber whose node is hidden or occluded gets no call per
/// post; it gets one ``EventCall/missed`` call when the node next shows.
@MainActor public final class AppEvents {
    private let fanOut: NotificationFanOut

    private static var associationKey: UInt8 = 0

    /// Observes every sender's notifications on `center`. The app uses ``of(_:)``, which keeps one
    /// per center; tests make their own.
    public init(center: NotificationCenter) {
        fanOut = NotificationFanOut(object: nil, center: center)
    }

    /// The app events of `center`, made on first use and kept alive by the center: the app's
    /// subscribers share `NotificationCenter.default`'s, a test's center has its own.
    public static func of(_ center: NotificationCenter) -> AppEvents {
        if let existing = objc_getAssociatedObject(center, &associationKey) as? AppEvents { return existing }
        let events = AppEvents(center: center)
        objc_setAssociatedObject(center, &associationKey, events, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return events
    }

    /// Calls `handler` for each post of `name`, by `node`'s visibility.
    ///
    /// - Parameters:
    ///   - name: The notification (from any sender).
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

    /// Calls `handler` for every post of `name`: for an owner with no node that decides for a
    /// whole window or the app (a window's key tracker).
    public func subscribe(_ name: Notification.Name, owner: String,
                          _ handler: @escaping @MainActor () -> Void) -> EventSubscription {
        fanOut.subscribe(name, node: nil, delivery: .always, owner: owner) { _ in handler() }
    }

    /// Whether a NotificationCenter observer for `name` exists (one while it has a subscriber).
    package func isObserving(_ name: Notification.Name) -> Bool { fanOut.isObserving(name) }

    /// How many subscriptions to `name` are live.
    package func subscriberCount(_ name: Notification.Name) -> Int { fanOut.subscriberCount(name) }

    /// How many posts of `name` the center delivered here: one per post, however many subscribers.
    package func deliveries(_ name: Notification.Name) -> Int { fanOut.deliveries(name) }
}
