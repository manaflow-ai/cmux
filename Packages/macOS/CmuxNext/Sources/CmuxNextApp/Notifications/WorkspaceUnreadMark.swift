import CmuxNextDaemon

/// Mark Workspace as Unread (`notification-mark-unread-v1`): a durable flag
/// on the workspace in the daemon, apart from notification markers. The
/// sidebar shows it as an unread dot. Like the old app's manual unread, it
/// clears when focus moves into the workspace or one of its notifications
/// is opened, and with Mark as Read.
enum WorkspaceUnreadMark {
    /// Sets or clears the mark on each workspace that differs.
    static func set(_ marked: Bool, on workspaces: [WorkspaceModel], daemon: DaemonService) {
        guard daemon.supports(DaemonCapabilities.notificationMarkUnread) else { return }
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
