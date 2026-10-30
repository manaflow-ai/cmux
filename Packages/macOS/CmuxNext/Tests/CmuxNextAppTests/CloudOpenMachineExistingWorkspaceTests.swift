@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Testing

/// Leo 2026-10-29: "no new workspaces or terminals as side effects". A machine's daemon connection
/// is up before its first tree is applied, so Open Machine (and New Cloud Workspace's open of a
/// new machine) read an empty list right after a resume and made a second workspace on a machine
/// that had one. The existing workspace is read once the tree is in.
@MainActor @Suite(.serialized)
struct CloudOpenMachineExistingWorkspaceTests {
    @Test func aTreeThatArrivesAfterTheConnectionIsReadNotReplaced() async {
        let store = DaemonStore()
        let read = Task { @MainActor in await CloudHandlers.existingWorkspace(in: store) }
        await Task.yield()
        store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-existing"), name: "workspace-1"),
        ]))
        #expect(await read.value == "ws-existing", "an empty list before the first tree made a second workspace")
    }

    /// After a resume the store still holds the last connection's tree: that list is not this
    /// connection's, so the read waits for the new tree (review finding).
    @Test func theLastConnectionsTreeIsNotReadAfterAReconnect() async {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(registryID: "s-vm"))
        store.connectionEpoch += 1
        let read = Task { @MainActor in await CloudHandlers.existingWorkspace(in: store) }
        await Task.yield()
        store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-made-meanwhile"), name: "workspace-1"),
        ]))
        #expect(await read.value == "ws-made-meanwhile", "the last connection's empty list made a second workspace")
    }

    @Test func aLoadedEmptyTreeHasNone() async {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(registryID: "s-vm"))
        #expect(await CloudHandlers.existingWorkspace(in: store) == nil)
    }
}
