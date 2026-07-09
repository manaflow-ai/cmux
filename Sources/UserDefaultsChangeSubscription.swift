import Foundation

/// Owns a `UserDefaults.didChangeNotification` observer and invokes its handler
/// synchronously on the main actor, matching the legacy inline TabManager
/// observer's `queue: .main` + `MainActor.assumeIsolated` timing. Carries no
/// payload: the notification is only a "settings changed" trigger.
final class UserDefaultsChangeSubscription {
    private let center: NotificationCenter
    private let observer: NSObjectProtocol

    init(
        center: NotificationCenter = .default,
        handler: @escaping @MainActor () -> Void
    ) {
        self.center = center
        observer = center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
    }

    deinit {
        center.removeObserver(observer)
    }
}
