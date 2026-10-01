import CmuxNextDaemon

/// Mark Workspace as Unread (`notification-mark-unread-v1`): a durable flag
/// on the workspace in the daemon, apart from notification markers. The
/// sidebar shows it as an unread dot and the Dock badge counts it once. Like
/// the old app's manual unread, it clears on typing into one of the
/// workspace's terminals and with Mark as Read or Clear Notifications;
/// focusing or opening the workspace keeps it. Typing clears marks of the
/// local daemon only (the notification service follows the local store).
enum WorkspaceUnreadMark {
    typealias Sent = (marked: Bool, at: ContinuousClock.Instant)

    /// The value last sent per workspace id.
    private static var sent: [String: Sent] = [:]

    /// How long a sent value counts as in flight. Typing asks for a clear on
    /// every keystroke until the echo lands; this sends one.
    static let echoWindow: Duration = .seconds(2)

    /// Sets or clears the mark on each workspace, through the daemon whose
    /// tree holds it (a group can span this Mac and remote machines).
    static func set(_ marked: Bool, on workspaces: [WorkspaceModel], machines: MachineRegistry) {
        for (workspace, daemon) in routes(workspaces, machines: machines) { set(marked, on: [workspace], daemon: daemon) }
    }

    /// Each workspace with the daemon whose tree holds it. Workspaces no
    /// daemon holds any more are left out.
    static func routes(_ workspaces: [WorkspaceModel], machines: MachineRegistry) -> [(workspace: WorkspaceModel, daemon: DaemonService)] {
        workspaces.compactMap { workspace in machines.daemon(forWorkspace: workspace.id).map { (workspace, $0) } }
    }

    /// Sets or clears the mark on each workspace of `daemon` that needs it.
    static func set(_ marked: Bool, on workspaces: [WorkspaceModel], daemon: DaemonService, now: ContinuousClock.Instant = .now) {
        guard daemon.supports(DaemonCapabilities.shared.notificationMarkUnread) else { return }
        for workspace in workspaces {
            guard let key = workspace.key, needsSend(marked, workspace.markedUnread, last: sent[workspace.id], now: now) else { continue }
            sent[workspace.id] = (marked, now)
            daemon.send("set-workspace-metadata") { _ = try await $0.setWorkspaceMetadata(key, markedUnread: marked) }
        }
    }

    /// Whether `marked` must go out for a workspace whose tree says `current`
    /// and whose last send was `last`. The same value sent within
    /// `echoWindow` is still in flight. Otherwise it goes out when the tree
    /// or the last send differs, so a clear asked for before a mark's echo
    /// arrives is not dropped.
    static func needsSend(_ marked: Bool, _ current: Bool, last: Sent?, now: ContinuousClock.Instant) -> Bool {
        if let last, last.marked == marked, now - last.at < echoWindow { return false }
        return current != marked || (last.map { $0.marked != marked } ?? false)
    }

    /// The workspace showing tab `tabID`.
    static func workspace(ofTab tabID: String, in store: DaemonStore) -> WorkspaceModel? {
        store.workspaces.first { workspace in
            workspace.screens.contains { $0.panes.contains { $0.tabs.contains { $0.id == tabID } } }
        }
    }
}
