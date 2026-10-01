import CmuxNextDaemon

/// Mark Workspace as Unread (`notification-mark-unread-v1`): a durable flag
/// on the workspace in the daemon, apart from notification markers. The
/// sidebar shows it as an unread dot and the Dock badge counts it once. Like
/// the old app's manual unread, it clears on typing into one of the
/// workspace's terminals and with Mark as Read; focusing or opening the
/// workspace keeps it. Typing clears marks of the local daemon only (the
/// notification service follows the local store).
enum WorkspaceUnreadMark {
    /// Sets or clears the mark on each workspace that differs.
    static func set(_ marked: Bool, on workspaces: [WorkspaceModel], daemon: DaemonService) {
        guard daemon.supports(DaemonCapabilities.shared.notificationMarkUnread) else { return }
        for workspace in workspaces where workspace.markedUnread != marked {
            guard let key = workspace.key else { continue }
            daemon.send("set-workspace-metadata") { _ = try await $0.setWorkspaceMetadata(key, markedUnread: marked) }
        }
    }

    /// The workspace showing tab `tabID`.
    static func workspace(ofTab tabID: String, in store: DaemonStore) -> WorkspaceModel? {
        store.workspaces.first { workspace in
            workspace.screens.contains { $0.panes.contains { $0.tabs.contains { $0.id == tabID } } }
        }
    }
}
