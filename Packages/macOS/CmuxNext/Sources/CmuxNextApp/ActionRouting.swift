import CmuxNextActions
import CmuxNextDaemon

/// Routes each action run to the machine that owns its explicit target.
///
/// Handlers command `services.activeDaemon`. Without routing that is the
/// active window's machine, so a context-menu or CLI run on a workspace,
/// tab, or group of another machine (another window, another sidebar
/// section) went to the wrong daemon. The registry's `invocationScope`
/// sets `services.routedDaemon` for the synchronous extent of the handler,
/// and `activeDaemon` returns it. Handlers resolve their daemon before any
/// `await` (never inside a detached Task), so the scope covers them.
enum ActionRouting {
    static func install(_ services: AppServices) {
        services.registry.invocationScope = { [weak services] invocation, body in
            guard let services else { return body() }
            let windows = services.windows.controllers
            let routed = daemon(for: invocation, daemons: services.machines.daemons) { windowID in
                windows.first { $0.state.id == windowID }.flatMap { services.machines.daemon(machine: $0.state.machineID) }
            }
            let previous = services.routedDaemon
            services.routedDaemon = routed ?? previous
            body()
            services.routedDaemon = previous
        }
    }

    /// The daemon owning the invocation's explicit target (`target`, else a
    /// workspace, tab, pane, or group argument), or nil for "the focused
    /// object's". `windowMachine` maps a window id to its machine's daemon.
    static func daemon(for invocation: ActionInvocation, daemons: [DaemonService],
                       windowMachine: (String) -> DaemonService?) -> DaemonService? {
        let arguments = ["workspace", "tab", "pane", "group"].compactMap { invocation[$0]?.targetValue }
        guard let target = invocation.target ?? arguments.first else { return nil }
        switch target.kind {
        case .machine:
            return daemons.first { $0.machineID == target.id }
        case .window:
            return windowMachine(target.id)
        case .workspace:
            return daemons.first { $0.store.workspaces.contains { $0.id == target.id } }
        case .workspaceGroup:
            return daemons.first { $0.store.group(WorkspaceGroupID(rawValue: target.id)) != nil }
        case .pane:
            return daemons.first { panes($0).contains { $0.id == target.id } }
        case .tab:
            return daemons.first { panes($0).contains { $0.tabs.contains { $0.id == target.id } } }
        case .tabGroup:
            return daemons.first { panes($0).contains { $0.tabGroups.contains { $0.id.rawValue == target.id } } }
        case .screen:
            return daemons.first { $0.store.workspaces.flatMap(\.screens).contains { $0.id == target.id } }
        case .screenGroup:
            return daemons.first { $0.store.workspaces.contains { $0.screenGroups.contains { $0.id.rawValue == target.id } } }
        case .column, .browserProfile:
            // Browser profiles are personal state of this Mac.
            return nil
        case .profile:
            return daemons.first { $0.store.profile(ProfileID(rawValue: target.id)) != nil }
        }
    }

    private static func panes(_ daemon: DaemonService) -> [PaneModel] {
        daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes)
    }
}
