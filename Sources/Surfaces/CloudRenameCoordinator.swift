import Foundation

/// Remote rename requests are process-wide because one daemon workspace or tab can be
/// projected into more than one local window. Keeping the lane here prevents two window
/// owners from sending the same remote identity out of order.
@MainActor
final class CloudRenameCoordinator {
    struct Key: Hashable, Sendable {
        enum Scope: String, Hashable, Sendable {
            case workspace
            case tab
            case terminal
        }

        let machine: SurfaceMachineID
        let scope: Scope
        let remoteID: String

        static func workspace(machine: SurfaceMachineID, id: String) -> Self {
            Self(machine: machine, scope: .workspace, remoteID: id)
        }

        static func tab(machine: SurfaceMachineID, id: String) -> Self {
            Self(machine: machine, scope: .tab, remoteID: id)
        }

        static func terminal(machine: SurfaceMachineID, id: String) -> Self {
            Self(machine: machine, scope: .terminal, remoteID: id)
        }
    }

    private struct Entry {
        let generation: UInt64
        let task: Task<Void, Error>
    }

    private struct PendingName {
        let generation: UInt64
        let value: String
        let task: Task<Void, Error>
    }

    /// The daemon cursor is global to one machine, so all remote rename writes
    /// share one lane. Identity keys remain separate for optimistic projection
    /// reconciliation.
    private var entries: [SurfaceMachineID: Entry] = [:]
    private var pendingNames: [Key: PendingName] = [:]
    private var nextGeneration: UInt64 = 0

    func pendingName(for key: Key) -> String? {
        pendingNames[key]?.value
    }

    /// Commits the names already chosen when a checkpoint was requested. Capture
    /// one task per identity: a later edit supersedes an earlier failure for that
    /// identity, but a failed workspace rename cannot hide behind a successful tab rename.
    func waitForPendingRenames(on machine: SurfaceMachineID) async throws {
        let pending = pendingNames.filter { $0.key.machine == machine }.values.sorted {
            $0.generation < $1.generation
        }
        try Task.checkCancellation()
        for name in pending {
            try await name.task.value
            try Task.checkCancellation()
        }
    }

    /// Serializes every remote rename for one machine across every local window and
    /// retains the newest optimistic name for each identity. A failed operation can
    /// compensate its own local view; an older completion cannot clear a newer intent
    /// or queue tail.
    @discardableResult
    func enqueue(
        key: Key,
        pendingName: String,
        operation: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Error> {
        let lane = key.machine
        nextGeneration &+= 1
        let generation = nextGeneration
        let pendingGeneration = generation
        let previous = entries[lane]?.task
        let task = Task { @MainActor [weak self] in
            defer { self?.finish(key: key, lane: lane, generation: generation, pendingGeneration: pendingGeneration) }
            if let previous {
                // A failed or cancelled rename must not strand later edits.
                _ = try? await previous.value
            }
            try Task.checkCancellation()
            try await operation()
        }
        entries[lane] = Entry(generation: generation, task: task)
        pendingNames[key] = PendingName(generation: pendingGeneration, value: pendingName, task: task)
        return task
    }

    private func finish(key: Key, lane: SurfaceMachineID, generation: UInt64, pendingGeneration: UInt64) {
        if pendingNames[key]?.generation == pendingGeneration {
            pendingNames[key] = nil
        }
        guard entries[lane]?.generation == generation else { return }
        entries[lane] = nil
    }
}
