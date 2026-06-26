import Foundation

/// Owns a `.ghosttyDidFocusSurface` observer and delivers typed focus changes
/// synchronously on the main actor, matching the legacy inline TabManager
/// observer's `queue: .main` + `MainActor.assumeIsolated` timing.
final class GhosttyFocusSurfaceSubscription {
    private let center: NotificationCenter
    private let observer: NSObjectProtocol

    init(
        center: NotificationCenter = .default,
        handler: @escaping @MainActor (GhosttyFocusSurfaceChange) -> Void
    ) {
        self.center = center
        observer = center.addObserver(
            forName: Notification.Name.ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { notification in
            guard let change = GhosttyFocusSurfaceChange(notification: notification) else { return }
            MainActor.assumeIsolated {
                handler(change)
            }
        }
    }

    deinit {
        center.removeObserver(observer)
    }
}
