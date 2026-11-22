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

    /// How long a throttled send counts as in flight. Typing asks for a clear
    /// on every keystroke until the echo lands; this sends one.
    static let echoWindow: Duration = .seconds(2)

    /// Sets or clears the mark on each workspace, through the daemon whose
    /// tree holds it (a group can span this Mac and remote machines).
    static func set(_ marked: Bool, on workspaces: [WorkspaceModel], machines: MachineRegistry) {
        for (workspace, daemon) in routes(workspaces, machines: machines) { set(marked, on: [workspace], daemon: daemon) }
    }

    /// Each workspace with the daemon whose tree holds it. Workspaces no
    /// daemon holds any more are left out.
    /// Matched by identity: daemons without the registry can share
    /// `handle:<n>` ids.
    static func routes(_ workspaces: [WorkspaceModel], machines: MachineRegistry) -> [(workspace: WorkspaceModel, daemon: DaemonService)] {
        workspaces.compactMap { workspace in
            machines.daemons.first { $0.store.workspaces.contains { $0 === workspace } }.map { (workspace, $0) }
        }
    }

    /// Sets or clears the mark on each workspace of `daemon` that needs it.
    /// `throttled` (typing) holds back a repeat of a value sent within
    /// `echoWindow`; a verb the user picks always goes out when it differs.
    static func set(_ marked: Bool, on workspaces: [WorkspaceModel], daemon: DaemonService, throttled: Bool = false,
                    now: ContinuousClock.Instant = .now) {
        guard daemon.supports(DaemonCapabilities.shared.notificationMarkUnread) else { return }
        for workspace in workspaces {
            guard let key = workspace.key, needsSend(marked, workspace.markedUnread, last: sent[workspace.id], throttled: throttled, now: now) else { continue }
            sent[workspace.id] = (marked, now)
            daemon.send("set-workspace-metadata") { _ = try await $0.setWorkspaceMetadata(key, markedUnread: marked) }
        }
    }

    /// Whether `marked` must go out for a workspace whose tree says `current`
    /// and whose last send was `last`. It goes out when the tree or the last
    /// send differs, so a clear asked for before a mark's echo arrives is not
    /// dropped. Throttled, the same value sent within `echoWindow` counts as
    /// still in flight.
    static func needsSend(_ marked: Bool, _ current: Bool, last: Sent?, throttled: Bool, now: ContinuousClock.Instant) -> Bool {
        if throttled, let last, last.marked == marked, now - last.at < echoWindow { return false }
        return current != marked || (last.map { $0.marked != marked } ?? false)
    }

    /// The workspace showing tab `tabID`.
    static func workspace(ofTab tabID: String, in store: DaemonStore) -> WorkspaceModel? {
        store.workspaces.first { workspace in
            workspace.screens.contains { $0.panes.contains { $0.tabs.contains { $0.id == tabID } } }
        }
    }
}
