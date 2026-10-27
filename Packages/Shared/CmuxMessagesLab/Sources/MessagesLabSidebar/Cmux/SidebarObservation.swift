import Foundation

/// cmux (Swift 6): a NotificationCenter observer whose handler runs on the main actor and that removes
/// itself when its owner releases it (a main-actor owner's `deinit` cannot read its tokens). The list's
/// copy of CmuxNextCompat's `MainActorObservation`, which this package cannot import.
final class SidebarObservation {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    /// Observes `name` from `object` (nil: any sender), delivering on the main actor.
    init(_ name: Notification.Name, object: AnyObject? = nil, center: NotificationCenter = .default,
         _ handler: @escaping @MainActor () -> Void) {
        self.center = center
        let delivery = MainQueueDelivery(handler: handler)
        token = center.addObserver(forName: name, object: object, queue: .main) { _ in delivery.run() }
    }

    deinit { center.removeObserver(token) }
}

/// The main-actor handler of an observer registered on the main queue: the one main-thread proof of
/// ``SidebarObservation``.
private struct MainQueueDelivery: Sendable {
    let handler: @MainActor () -> Void

    func run() {
        MainActor.assumeIsolated { handler() } // main-proof: SidebarObservation registers on queue: .main, which runs its blocks on the main thread
    }
}
