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
            personScoped(body)
            services.routedDaemon = previous
        }
        // A run's completion (ActionCompletion) binds its command scope again where it runs, outside the run's task tree.
        services.registry.runLocals = { CommandScopeLocals(scope: DaemonCommandScope.current) }
    }

    /// The ``DaemonCommandScope`` of a run, bound again in the tasks its completion posts or starts: their commands
    /// keep the run's tickets (the CLI's `action.run` waits for them), derived keys and person cause.
    private nonisolated struct CommandScopeLocals: ActionRunLocals {
        let scope: DaemonCommandScope?

        @MainActor func bind<T>(_ body: () -> T) -> T { DaemonCommandScope.$current.withValueInTask(scope, operation: body) }

        func bindAwaiting<T>(_ body: () async -> T) async -> T {
            await DaemonCommandScope.$current.withValueAwaiting(scope, operation: body)
        }
    }

    /// Runs a person's action run in a person ``DaemonCommandScope``, so the echoes of what it
    /// sends apply as `person` (plans/cmux-next/chrome-parity/p06-scheduler.md, "Person cause, app
    /// side"). The run's effective origin decides (``ActionRunScope/current``, which a nested run
    /// takes from the outer one), never the handed invocation's: a script's handler that performs
    /// another action with a default invocation stays the script's. A run inside a control-socket
    /// scope keeps that scope.
    static func personScoped(_ body: () -> Void) {
        guard ActionRunScope.current?.origin == .user, DaemonCommandScope.current == nil else { return body() }
        DaemonCommandScope.$current.withValueInTask(DaemonCommandScope.person(), operation: body)
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
            return GroupOwnership.daemon(holdingTabGroup: TabGroupID(rawValue: target.id), in: daemons)
        case .screen:
            return daemons.first { $0.store.workspaces.flatMap(\.screens).contains { $0.id == target.id } }
        case .screenGroup:
            return GroupOwnership.daemon(holdingScreenGroup: ScreenGroupID(rawValue: target.id), in: daemons)
        case .column, .browserProfile, .bookmark, .sidebarItem, .sidebarSection, .agentChat:
            // Browser profiles, bookmarks, the sidebar layout and the Priority
            // view's marks on a chat are personal state, not a machine daemon's.
            return nil
        case .profile:
            return daemons.first { $0.store.profile(ProfileID(rawValue: target.id)) != nil }
        }
    }

    private static func panes(_ daemon: DaemonService) -> [PaneModel] {
        daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes)
    }
}
