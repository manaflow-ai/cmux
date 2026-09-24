import CmuxSurfaceCatalogModel
import Foundation
import Observation

/// Catalog-owned deletion intents. Authoritative rows are never destructively
/// edited to implement optimism, so rollback cannot overwrite a concurrent edit.
@MainActor
@Observable
final class CloudWorkspaceDeletionLedger {
    struct Key: Hashable, Sendable {
        let machine: SurfaceMachineID
        let workspaceID: String
    }
    struct Entry {
        let token: UUID
        var terminalIDs: Set<SurfaceResourceID>
        var completed = false
        var absentAt: CloudVMCursor?
        var task: Task<Int, Error>?
        var closedTerminalCount = 0
    }
    private struct TerminalKey: Hashable {
        let resource: SurfaceResourceID
        let provider: ObjectIdentifier
    }
    private var terminalTasks: [TerminalKey: Task<Void, Error>] = [:]

    /// Concurrent workspace deletes share a terminal close while either request
    /// is pending. Completed terminal receipts disappear when the lane drains.
    func closeTerminal(_ id: SurfaceResourceID, provider: any SurfaceProvider) async throws {
        let key = TerminalKey(resource: id, provider: ObjectIdentifier(provider))
        if let existing = terminalTasks[key] { return try await existing.value }
        let task = Task { @MainActor in try await provider.closeTerminal(id) }
        terminalTasks[key] = task
        try await task.value
    }

    private func releaseTerminalTasksIfIdle(on machine: SurfaceMachineID) {
        guard !entries.contains(where: { $0.key.machine == machine && !$0.value.completed }) else { return }
        terminalTasks = terminalTasks.filter { $0.key.resource.machine != machine }
    }

    private(set) var entries: [Key: Entry] = [:]

    var pending: [SurfaceMachineID: Set<String>] {
        var result: [SurfaceMachineID: Set<String>] = [:]
        for (key, entry) in entries where !entry.completed {
            result[key.machine, default: []].insert(key.workspaceID)
        }
        return result
    }

    func begin(machine: SurfaceMachineID, workspaceID: String, previous: SurfaceCatalogSnapshot = .empty) -> UUID? {
        let key = Key(machine: machine, workspaceID: workspaceID)
        guard entries[key] == nil else { return nil }
        let token = UUID()
        entries[key] = Entry(token: token, terminalIDs: Set(previous.resources.filter {
            $0.machine == machine && $0.kind == .terminal && $0.remoteWorkspaces.contains { $0.id == workspaceID }
        }.map(\.id)))
        return token
    }

    func attach(_ task: Task<Int, Error>, key: Key, token: UUID) {
        guard entries[key]?.token == token else { return }
        entries[key]?.task = task
    }

    func rememberTerminals(_ ids: Set<SurfaceResourceID>, key: Key, token: UUID) {
        guard entries[key]?.token == token else { return }
        entries[key]?.terminalIDs.formUnion(ids)
    }

    @discardableResult
    func succeed(machine: SurfaceMachineID, workspaceID: String, token: UUID, closedTerminalCount: Int = 0) -> Bool {
        let key = Key(machine: machine, workspaceID: workspaceID)
        guard entries[key]?.token == token, entries[key]?.completed == false else { return false }
        entries[key]?.completed = true
        entries[key]?.task = nil
        entries[key]?.closedTerminalCount = closedTerminalCount
        releaseTerminalTasksIfIdle(on: machine)
        return true
    }

    @discardableResult
    func fail(machine: SurfaceMachineID, workspaceID: String, token: UUID) -> Bool {
        let key = Key(machine: machine, workspaceID: workspaceID)
        guard entries[key]?.token == token, entries[key]?.completed == false else { return false }
        entries[key] = nil
        releaseTerminalTasksIfIdle(on: machine)
        return true
    }

    func hides(machine: SurfaceMachineID, workspaceID: String) -> Bool {
        entries[Key(machine: machine, workspaceID: workspaceID)] != nil
    }

    func isPending(machine: SurfaceMachineID, workspaceID: String) -> Bool {
        entries[Key(machine: machine, workspaceID: workspaceID)]?.completed == false
    }

    /// Keep a generation/revision fence after confirmation. A reused workspace ID
    /// is admitted only in a strictly newer accepted graph, never by a stale refresh.
    func reconcile(_ state: CloudVMState) {
        guard state.document.containsCollection("workspaces"), let cursor = state.cursor else { return }
        for (key, entry) in entries where key.machine == state.machine && entry.completed {
            if !state.workspaceIDs.contains(key.workspaceID) {
                if entry.absentAt == nil || cursor.generation != entry.absentAt?.generation || cursor.isNewer(than: entry.absentAt) {
                    entries[key]?.absentAt = cursor
                }
            } else if let absent = entry.absentAt,
                      cursor.generation == absent.generation && cursor.revision > absent.revision {
                entries[key] = nil
            }
        }
    }

    func remove(machine: SurfaceMachineID) {
        for (key, task) in terminalTasks where key.resource.machine == machine {
            task.cancel()
            terminalTasks[key] = nil
        }
        for (key, entry) in entries where key.machine == machine {
            entry.task?.cancel()
            entries[key] = nil
        }
    }
}
