import Foundation

/// Owns a `.workspaceCurrentDirectoryDidChange` observer and delivers the
/// affected workspace id synchronously on the main actor, matching the legacy
/// inline TabManager observer's `queue: .main` + `MainActor.assumeIsolated`
/// timing. The id is read from `userInfo["workspaceId"]`, falling back to the
/// notification's `Workspace` object; the `Workspace` access must stay inside
/// the isolated body, so the decode lives there rather than in a payload type.
final class WorkspaceCurrentDirectorySubscription {
    private let center: NotificationCenter
    private let observer: NSObjectProtocol

    init(
        center: NotificationCenter = .default,
        handler: @escaping @MainActor (UUID) -> Void
    ) {
        self.center = center
        observer = center.addObserver(
            forName: Notification.Name.workspaceCurrentDirectoryDidChange,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                let workspaceId = notification.userInfo?["workspaceId"] as? UUID
                    ?? (notification.object as? Workspace)?.id
                guard let workspaceId else { return }
                handler(workspaceId)
            }
        }
    }

    deinit {
        center.removeObserver(observer)
    }
}
