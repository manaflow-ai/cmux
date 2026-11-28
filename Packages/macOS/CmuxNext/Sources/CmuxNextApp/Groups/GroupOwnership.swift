import CmuxNextDaemon

/// Which machine's daemon owns a group: the one whose tree holds it. Every
/// tab group and screen group path asks here (action routing, screen group
/// targets, whole-group moves, group handlers), never the local or the
/// active daemon by default (OWNERSHIP-PRINCIPLES: one code path picks the
/// owner). Workspaces never mix machines, so a group may only move to, or
/// take members from, panes and workspaces on its own daemon.
@MainActor
enum GroupOwnership {
    /// The daemon whose tree holds tab group `group`, nil when none does.
    static func daemon(holdingTabGroup group: TabGroupID, in daemons: [DaemonService]) -> DaemonService? {
        daemons.first { pane(holdingTabGroup: group, in: $0) != nil }
    }

    static func daemon(holdingTabGroup group: TabGroupID, machines: MachineRegistry) -> DaemonService? {
        daemon(holdingTabGroup: group, in: machines.daemons)
    }

    /// The pane holding tab group `group` and the daemon that owns it.
    static func pane(holdingTabGroup group: TabGroupID, machines: MachineRegistry) -> (pane: PaneModel, daemon: DaemonService)? {
        for daemon in machines.daemons {
            if let pane = pane(holdingTabGroup: group, in: daemon) { return (pane, daemon) }
        }
        return nil
    }

    /// The daemon whose tree holds screen group `group`, nil when none does.
    static func daemon(holdingScreenGroup group: ScreenGroupID, in daemons: [DaemonService]) -> DaemonService? {
        daemons.first { workspace(holdingScreenGroup: group, in: $0) != nil }
    }

    static func daemon(holdingScreenGroup group: ScreenGroupID, machines: MachineRegistry) -> DaemonService? {
        daemon(holdingScreenGroup: group, in: machines.daemons)
    }

    /// The workspace holding screen group `group`, its record and its daemon.
    static func screenGroup(_ group: ScreenGroupID, machines: MachineRegistry)
        -> (workspace: WorkspaceModel, group: ScreenGroupSnapshot, daemon: DaemonService)? {
        for daemon in machines.daemons {
            if let workspace = workspace(holdingScreenGroup: group, in: daemon),
               let record = workspace.screenGroups.first(where: { $0.id == group }) {
                return (workspace, record, daemon)
            }
        }
        return nil
    }

    /// The owner of tab group `group` when `target` (a pane it would move
    /// to, or the pane of a tab joining it) is on the same machine; nil
    /// otherwise (refused).
    static func owner(ofTabGroup group: TabGroupID, sameMachineAs target: DaemonService, machines: MachineRegistry) -> DaemonService? {
        guard let owner = daemon(holdingTabGroup: group, machines: machines), owner === target else { return nil }
        return owner
    }

    private static func pane(holdingTabGroup group: TabGroupID, in daemon: DaemonService) -> PaneModel? {
        daemon.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).first { $0.tabGroups.contains { $0.id == group } }
    }

    private static func workspace(holdingScreenGroup group: ScreenGroupID, in daemon: DaemonService) -> WorkspaceModel? {
        daemon.store.workspaces.first { $0.screenGroups.contains { $0.id == group } }
    }
}
