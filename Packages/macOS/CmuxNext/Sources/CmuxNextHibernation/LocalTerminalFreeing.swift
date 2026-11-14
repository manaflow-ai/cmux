public import CmuxNextBridge

/// The freeing tier on this Mac's daemon (plans/cmux-next/sidebar-recents-and-freeing-DESIGN.md): the daemon's
/// terminal facts as the planner's ``WorkspaceFreeingPlanner/Terminal``, and its park.
///
/// ```swift
/// WorkspaceHibernation(host: services, keepAwake: keepAwake, deadline: deadline,
///                      terminals: LocalTerminalFreeing(DaemonParkableTerminals(store: store, connection: { connection })))
/// ```
@MainActor
public final class LocalTerminalFreeing: WorkspaceTerminalFreeing {
    private let daemon: DaemonParkableTerminals

    /// - Parameter daemon: this Mac's daemon reads and park.
    public init(_ daemon: DaemonParkableTerminals) {
        self.daemon = daemon
    }

    /// This Mac's terminal tabs of `workspaces`, with the facts that keep each shell running.
    public func terminals(in workspaces: Set<String>) -> [WorkspaceFreeingPlanner.Terminal] {
        daemon.terminals(in: workspaces).map { tab in
            WorkspaceFreeingPlanner.Terminal(
                surface: tab.surface, workspace: tab.workspace, workspaceLastActive: tab.workspaceLastActive,
                workspaceKept: tab.workspaceKept, promptSince: tab.promptSince, lastOutput: tab.lastOutput,
                programReported: tab.programReported, local: tab.local, ended: tab.ended,
                agent: tab.runsAgent ? (tab.agentResumable ? .resumable : .working) : nil, commandSince: tab.commandSince)
        }
    }

    /// Parks `surfaces`: their shells end, their tabs stay and start again when shown.
    public func park(_ surfaces: [String]) {
        daemon.park(surfaces)
    }
}
