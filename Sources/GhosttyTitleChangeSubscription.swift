import Foundation

/// Owns a `.ghosttyDidSetTitle` observer and delivers typed title changes.
final class GhosttyTitleChangeSubscription {
    private let center: NotificationCenter
    private let observer: NSObjectProtocol

    init(
        center: NotificationCenter = .default,
        handler: @escaping @MainActor (GhosttyTitleChange) -> Void
    ) {
        self.center = center
        observer = center.addObserver(
            forName: Notification.Name.ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { notification in
            guard let change = GhosttyTitleChange(notification: notification) else { return }
            Task { @MainActor in
                handler(change)
            }
        }
    }

    deinit {
        center.removeObserver(observer)
    }
}
