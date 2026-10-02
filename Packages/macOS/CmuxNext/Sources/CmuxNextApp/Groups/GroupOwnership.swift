import CmuxNextDaemon

/// Which machine's daemon owns a group: the one whose tree holds it. Group
/// commands (tab groups, screen groups) go to that daemon, never to the
/// local or the active one by default (OWNERSHIP-PRINCIPLES: one code path
/// picks the owner). Workspaces never mix machines, so a group and every
/// pane or workspace it can move to within one command share that daemon.
@MainActor
enum GroupOwnership {
    /// The daemon whose tree holds tab group `group`, nil when none does.
    static func daemon(holdingTabGroup group: TabGroupID, machines: MachineRegistry) -> DaemonService? {
        machines.daemons.first { daemon in pane(holdingTabGroup: group, in: daemon) != nil }
    }

    /// The pane holding tab group `group` and the daemon that owns it.
    static func pane(holdingTabGroup group: TabGroupID, machines: MachineRegistry) -> (pane: PaneModel, daemon: DaemonService)? {
        for daemon in machines.daemons {
            if let pane = pane(holdingTabGroup: group, in: daemon) { return (pane, daemon) }
        }
        return nil
    }

    /// The daemon whose tree holds screen group `group`, nil when none does.
    static func daemon(holdingScreenGroup group: ScreenGroupID, machines: MachineRegistry) -> DaemonService? {
        machines.daemons.first { daemon in daemon.store.workspaces.contains { $0.screenGroups.contains { $0.id == group } } }
    }

    private static func pane(holdingTabGroup group: TabGroupID, in daemon: DaemonService) -> PaneModel? {
        daemon.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).first { $0.tabGroups.contains { $0.id == group } }
    }
}
