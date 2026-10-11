import Foundation

/// The bookkeeping of ``ClosedWorkspaceTracker``: which workspaces each connected machine showed,
/// and the newest ``capacity`` closed ones. Every change that drops entries returns them, so the
/// tracker can expire what they own (their agent-home folders).
struct ClosedWorkspaceLog {
    struct Record: Equatable {
        var id = UUID().uuidString
        var machine: String
        var name: String
        var cwd: String?
        var tabCount: Int
        var closedAt: Date
        var isIncognito = false
        /// The workspace id that names its agent-home folder (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE),
        /// for a workspace on this Mac; nil elsewhere.
        var agentHomeID: String?
    }

    /// What every connected machine shows now: its boot generation and its workspaces by id.
    struct Snapshot: Sendable {
        struct Machine: Sendable {
            var generation: String
            var workspaces: [String: Record]
        }

        var machines: [String: Machine]
    }

    static let capacity = 20
    private(set) var records: [Record] = []
    /// What each machine showed last: workspace id to its record.
    private var known: [String: [String: Record]] = [:]
    private var generations: [String: String] = [:]

    /// Records the workspaces that left a machine whose boot generation did not change (a machine
    /// that drops or restarts takes its workspaces out without recording them). Returns the entries
    /// that fell off the end.
    mutating func apply(_ snapshot: Snapshot) -> [Record] {
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
        guard records.count > Self.capacity else { return [] }
        let expired = Array(records.prefix(records.count - Self.capacity))
        records.removeFirst(records.count - Self.capacity)
        return expired
    }

    mutating func take(_ id: String) -> Record? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        return records.remove(at: index)
    }

    /// Puts a record back (a reopen that could not run).
    mutating func restore(_ record: Record) {
        records.append(record)
        records.sort { $0.closedAt < $1.closedAt }
    }

    /// Drops the entries closed at or after `since` (every entry for nil) and returns them.
    mutating func clear(since: Date?) -> [Record] {
        let dropped = records.filter { record in since.map { record.closedAt >= $0 } ?? true }
        records.removeAll { record in since.map { record.closedAt >= $0 } ?? true }
        return dropped
    }
}
