import Foundation

/// Owns a `.ghosttyDidSetTitle` observer and delivers typed title changes.
final class GhosttyTitleChangeSubscription {
    private let center: NotificationCenter
    private let observer: NSObjectProtocol

    /// - Parameter synchronous: when `true`, the handler runs synchronously on
    ///   the main-queue delivery via `MainActor.assumeIsolated` (matching the
    ///   legacy inline TabManager observer timing). When `false` (default), the
    ///   handler is hopped through `Task { @MainActor in }` as before.
    init(
        center: NotificationCenter = .default,
        synchronous: Bool = false,
        handler: @escaping @MainActor (GhosttyTitleChange) -> Void
    ) {
        self.center = center
        observer = center.addObserver(
            forName: Notification.Name.ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { notification in
            guard let change = GhosttyTitleChange(notification: notification) else { return }
            if synchronous {
                MainActor.assumeIsolated {
                    handler(change)
                }
            } else {
                Task { @MainActor in
                    handler(change)
                }
            }
        }
    }

    deinit {
        center.removeObserver(observer)
    }
}
