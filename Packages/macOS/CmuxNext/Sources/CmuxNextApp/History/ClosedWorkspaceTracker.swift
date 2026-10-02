import CmuxNextDaemon
import Foundation
import Observation

/// Recently closed workspaces for history lists (plans/cmux-next/history.md
/// 2, `closed`). A workspace that leaves a connected machine's tree while the
/// daemon keeps its boot generation counts as closed; a machine that drops
/// or restarts takes its workspaces out without recording them. Incognito
/// workspaces are never recorded. A workspace close ends its terminals, so
/// Reopen makes a new workspace with the same name in the same directory.
final class ClosedWorkspaceTracker {
    struct Record: Equatable {
        var id = UUID().uuidString
        var machine: String
        var name: String
        var cwd: String?
        var tabCount: Int
        var closedAt: Date
        var isIncognito = false
    }

    static let capacity = 20
    private unowned let services: AppServices
    private(set) var records: [Record] = []
    /// What each machine showed last: workspace id to its record.
    private var known: [String: [String: Record]] = [:]
    private var generations: [String: String] = [:]
    private var observation: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
        let machines = services.machines
        observation = Task { [weak self, weak services] in
            for await snapshot in Observations({
                Self.snapshot(of: machines.daemons) { services?.windows?.isIncognito(workspace: $0) ?? false }
            }) {
                self?.apply(snapshot)
            }
        }
    }

    deinit { observation?.cancel() }

    private struct Snapshot: Sendable {
        var machines: [String: (generation: String, workspaces: [String: Record])]
    }

    private static func snapshot(of daemons: [DaemonService], incognito: (String) -> Bool) -> Snapshot {
        var machines: [String: (String, [String: Record])] = [:]
        for daemon in daemons {
            let store = daemon.store
            guard case .connected = store.connectionState, store.isLoaded else { continue }
            var workspaces: [String: Record] = [:]
            for workspace in store.workspaces {
                let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
                workspaces[workspace.id] = Record(machine: daemon.machineID, name: workspace.displayName,
                                                  cwd: tabs.lazy.compactMap(\.cwd).first, tabCount: tabs.count, closedAt: Date(),
                                                  isIncognito: incognito(workspace.id))
            }
            machines[daemon.machineID] = (store.generation?.rawValue ?? "", workspaces)
        }
        return Snapshot(machines: machines)
    }

    private func apply(_ snapshot: Snapshot) {
        for (machine, current) in snapshot.machines {
            defer {
                known[machine] = current.workspaces
                generations[machine] = current.generation
            }
            guard generations[machine] == current.generation, let previous = known[machine] else { continue }
            for (id, record) in previous where current.workspaces[id] == nil {
                guard !record.isIncognito else { continue }
                var closed = record
                closed.closedAt = Date()
                records.append(closed)
            }
        }
        // A machine that dropped forgets its baseline (no closes recorded).
        for machine in known.keys where snapshot.machines[machine] == nil { known[machine] = nil }
        if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
    }

    func take(_ id: String) -> Record? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        return records.remove(at: index)
    }

    /// Puts a record back (a reopen that could not run).
    func restore(_ record: Record) {
        records.append(record)
        records.sort { $0.closedAt < $1.closedAt }
    }

    func clear(since: Date?) {
        records.removeAll { record in since.map { record.closedAt >= $0 } ?? true }
    }
}
