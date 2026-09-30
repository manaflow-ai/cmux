import Foundation
import Testing
@testable import CmuxNextDaemon

/// `onWorkspaceListChanged` runs synchronously, once per applied batch,
/// only when workspace membership or order changed, so the App can close a
/// window in the same turn as the delta that emptied it.
@MainActor @Suite struct WorkspaceListHookTests {
    private func workspace(_ name: String, key: String, handle: UInt64) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: WorkspaceHandle(rawValue: handle), key: WorkspaceKey(rawValue: key), name: name)
    }

    @Test func firesOncePerBatchOnlyWhenTheListChanges() throws {
        let store = DaemonStore()
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        let generation = try #require(store.generation)
        var calls: [[String]] = []
        store.onWorkspaceListChanged = { calls.append(store.workspaces.map(\.name)) }

        // Two adds in one batch: one call, after both applied.
        let added = [
            WorkspaceDelta(workspace: 21, index: 0, entity: workspace("delta", key: "k-delta", handle: 21), workspaceRevision: 4,
                           generation: generation),
            WorkspaceDelta(workspace: 22, index: 0, entity: workspace("eps", key: "k-eps", handle: 22), workspaceRevision: 5,
                           generation: generation),
        ]
        store.apply(batch: added.enumerated().map { DaemonEventEnvelope(sequence: UInt64(10 + $0), event: .workspaceAdded($1)) })
        #expect(calls == [["eps", "delta", "beta", "gamma"]])

        // A title change is not a list change.
        store.apply(.titleChanged(surface: 3, title: "vim"))
        #expect(calls.count == 1)

        // A close outside a batch reports at once.
        let closed = WorkspaceDelta(workspace: 22, index: 0, entity: workspace("eps", key: "k-eps", handle: 22), workspaceRevision: 6,
                                    generation: generation)
        store.apply(.workspaceClosed(closed))
        #expect(calls.last == ["delta", "beta", "gamma"])

        // A snapshot that drops everything reports the empty list.
        store.apply(snapshot: DaemonTree(workspaceRevision: 7, workspaces: []))
        #expect(calls.last == [])
        #expect(calls.count == 3)
    }
}
