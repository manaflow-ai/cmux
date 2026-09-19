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
        var previous: SurfaceCatalogSnapshot?
        var terminalIDs: Set<SurfaceResourceID>
        var completed = false
        var absentAt: CloudVMCursor?
        var task: Task<Int, Error>?
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
        entries[key] = Entry(token: token, previous: previous, terminalIDs: Set(previous.resources.filter {
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
    func succeed(machine: SurfaceMachineID, workspaceID: String, token: UUID) -> Bool {
        let key = Key(machine: machine, workspaceID: workspaceID)
        guard entries[key]?.token == token, entries[key]?.completed == false else { return false }
        entries[key]?.completed = true
        entries[key]?.previous = nil
        return true
    }

    @discardableResult
    func fail(machine: SurfaceMachineID, workspaceID: String, token: UUID) -> Bool {
        let key = Key(machine: machine, workspaceID: workspaceID)
        guard entries[key]?.token == token, entries[key]?.completed == false else { return false }
        entries[key] = nil
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
                if entry.absentAt == nil || cursor.isNewer(than: entry.absentAt) {
                    entries[key]?.absentAt = cursor
                }
            } else if let absent = entry.absentAt,
                      cursor.generation != absent.generation || cursor.revision > absent.revision {
                entries[key] = nil
            }
        }
    }

    func remove(machine: SurfaceMachineID) {
        for (key, entry) in entries where key.machine == machine {
            entry.task?.cancel()
            entries[key] = nil
        }
    }
}
