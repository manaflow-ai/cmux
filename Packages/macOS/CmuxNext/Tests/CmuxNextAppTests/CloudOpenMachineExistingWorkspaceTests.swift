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
        _ = store.apply(.connected(DaemonIdentity(generation: "first"), generationChanged: false))
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
        _ = store.apply(.connected(DaemonIdentity(generation: "before"), generationChanged: false))
        store.apply(snapshot: DaemonTree(registryID: "s-vm"))
        _ = store.apply(.disconnected(reason: "paused"))
        _ = store.apply(.connected(DaemonIdentity(generation: "resumed"), generationChanged: false))
        let read = Task { @MainActor in await CloudHandlers.existingWorkspace(in: store) }
        await Task.yield()
        store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-made-meanwhile"), name: "workspace-1"),
        ]))
        #expect(await read.value == "ws-made-meanwhile", "the last connection's empty list made a second workspace")
    }

    /// The daemon's connection is published before the store hears `.connected` (which moves the
    /// epoch): a read in that window still waits for the new connection's tree (review finding).
    @Test func aReadBeforeTheStoreHearsTheConnectionWaits() async {
        let store = DaemonStore()
        // A tree the store holds before any connection (the machine's launch snapshot): its epoch
        // is the store's, so only the connected state tells it is not this connection's.
        store.apply(snapshot: DaemonTree(registryID: "s-vm"))
        let read = Task { @MainActor in await CloudHandlers.existingWorkspace(in: store) }
        await Task.yield()
        _ = store.apply(.connected(DaemonIdentity(generation: "resumed"), generationChanged: false))
        store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-made-meanwhile"), name: "workspace-1"),
        ]))
        #expect(await read.value == "ws-made-meanwhile", "a read before the store heard the connection took the old list")
    }

    @Test func aLoadedEmptyTreeHasNone() async {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "live"), generationChanged: false))
        store.apply(snapshot: DaemonTree(registryID: "s-vm"))
        #expect(await CloudHandlers.existingWorkspace(in: store) == nil)
    }
}
