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
        token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { handler() } // main-proof: the observer is registered on the main queue (queue: .main)
        }
    }

    deinit { center.removeObserver(token) }
}
