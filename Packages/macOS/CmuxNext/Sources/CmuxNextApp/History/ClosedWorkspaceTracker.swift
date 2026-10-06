import CmuxNextDaemon
import Foundation
import Observation

/// Recently closed workspaces for history lists (plans/cmux-next/history.md
/// 2, `closed`). A workspace that leaves a connected machine's tree while the
/// daemon keeps its boot generation counts as closed; a machine that drops
/// or restarts takes its workspaces out without recording them. Incognito
/// workspaces are never recorded. A workspace close ends its terminals, so
/// Reopen makes a new workspace with the same name in the same directory.
///
/// A close never touches a workspace's agent-home folder; an entry that
/// expires (it falls off the end, or the user removes it or clears History)
/// sends the folder to the Trash (``AgentHomeHistory``).
final class ClosedWorkspaceTracker {
    typealias Record = ClosedWorkspaceLog.Record

    static let capacity = ClosedWorkspaceLog.capacity
    private var log = ClosedWorkspaceLog()
    var records: [Record] { log.records }
    let agentHomes: AgentHomeHistory
    private var observation: Task<Void, Never>?

    init(services: AppServices) {
        agentHomes = AgentHomeHistory()
        let machines = services.machines
        observation = Task { [weak self, weak services] in
            for await snapshot in Observations({
                Self.snapshot(of: machines.daemons) { services?.windows?.isIncognito(workspace: $0) ?? false }
            }) {
                self?.apply(snapshot)
            }
        }
    }

    /// A tracker fed by hand (tests).
    init(agentHomes: AgentHomeHistory) {
        self.agentHomes = agentHomes
    }

    deinit { observation?.cancel() }

    private static func snapshot(of daemons: [DaemonService], incognito: (String) -> Bool) -> ClosedWorkspaceLog.Snapshot {
        var machines: [String: ClosedWorkspaceLog.Snapshot.Machine] = [:]
        for daemon in daemons {
            let store = daemon.store
            guard case .connected = store.connectionState, store.isLoaded else { continue }
            var workspaces: [String: Record] = [:]
            for workspace in store.workspaces {
                let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
                workspaces[workspace.id] = Record(machine: daemon.machineID, name: workspace.displayName,
                                                  cwd: tabs.lazy.compactMap(\.cwd).first, tabCount: tabs.count, closedAt: Date(),
                                                  isIncognito: incognito(workspace.id),
                                                  agentHomeID: daemon.isLocal ? workspace.id : nil)
            }
            machines[daemon.machineID] = .init(generation: store.generation?.rawValue ?? "", workspaces: workspaces)
        }
        return ClosedWorkspaceLog.Snapshot(machines: machines)
    }

    func apply(_ snapshot: ClosedWorkspaceLog.Snapshot) {
        expire(log.apply(snapshot))
    }

    /// Takes a record to reopen it; its agent-home folder moves to the new workspace
    /// (``AgentHomeHistory/reopened(from:to:)``).
    func take(_ id: String) -> Record? {
        log.take(id)
    }

    /// The key of the workspace that reopens `record`: a fresh one, and the record's agent-home
    /// folder already moved to it.
    func reopenKey(for record: Record) -> WorkspaceKey {
        let key = WorkspaceKey.generate()
        agentHomes.reopened(from: record.agentHomeID, to: key.rawValue)
        return key
    }

    /// Removes an entry from History: it expires.
    func discard(_ id: String) {
        guard let record = log.take(id) else { return }
        expire([record])
    }

    /// Puts a record back (a reopen that could not run).
    func restore(_ record: Record) {
        log.restore(record)
    }

    func clear(since: Date?) {
        expire(log.clear(since: since))
    }

    private func expire(_ records: [Record]) {
        let ids = records.compactMap(\.agentHomeID)
        if !ids.isEmpty { agentHomes.expired(ids) }
    }
}
