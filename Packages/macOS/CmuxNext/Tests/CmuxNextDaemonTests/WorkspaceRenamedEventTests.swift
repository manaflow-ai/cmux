import Testing
@testable import CmuxNextDaemon

/// A remote daemon's workspace-renamed event patches the existing model in place.
/// The sidebar reads ``WorkspaceModel.displayName`` from that model, so the title
/// must change without replacing the row's identity.
@MainActor
struct WorkspaceRenamedEventTests {
    @Test func workspaceRenamedEventUpdatesExistingWorkspaceDisplayName() throws {
        let key = WorkspaceKey(rawValue: "remote-workspace")
        let handle = WorkspaceHandle(rawValue: 7)
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 4, workspaces: [
            WorkspaceSnapshot(id: handle, key: key, name: "Before")
        ]))
        let existing = try #require(store.workspace(id: key.rawValue))

        let renamed = WorkspaceSnapshot(id: handle, key: key, name: "After")
        let followup = store.apply(.workspaceRenamed(WorkspaceDelta(
            workspace: handle,
            index: nil,
            entity: renamed,
            workspaceRevision: 5
        )))

        #expect(followup == .none)
        #expect(store.workspace(id: key.rawValue) === existing)
        #expect(existing.name == "After")
        #expect(existing.displayName == "After")
    }
}
