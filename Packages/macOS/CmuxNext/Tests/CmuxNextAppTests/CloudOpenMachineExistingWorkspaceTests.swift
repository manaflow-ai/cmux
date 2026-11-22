import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
@testable import CmuxNextDaemon
import Testing

/// Leo 2026-10-29: "no new workspaces or terminals as side effects". A machine's daemon connection
/// is up before its first tree is applied, so Open Machine (and New Cloud Workspace's open of a
/// new machine) read an empty list right after a resume and made a second workspace on a machine
/// that had one. The existing workspace is read once the tree is in.
@MainActor @Suite(.serialized)
struct CloudOpenMachineExistingWorkspaceTests {
    static let notConnected = ActionFailure(message: "not connected")

    /// Capture d143d61c: machines made from one image list the same key for their first workspace,
    /// and the app finds a workspace by its id alone, so a chat start's chat opened in that workspace
    /// was shown in another machine's: its page never loaded and its first message never went. A
    /// workspace another tree lists is never the anchor; the machine gets a workspace of its own.
    @Test func aWorkspaceAnotherMachineListsIsNotTheAnchor() async throws {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "live"), generationChanged: false))
        store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-from-the-image"), name: "workspace-1"),
        ]))
        var calls: [String] = []
        let result = try await CloudMachineWorkspace.first(in: store, notConnected: Self.notConnected,
                                                           listedElsewhere: { $0 == "ws-from-the-image" },
                                                           beforeCreate: { calls.append("proceed") }) {
            calls.append("create")
            return "ws-own"
        }
        #expect(result.id == "ws-own", "the chat was opened in a workspace another machine also lists")
        #expect(result.created)
        #expect(calls == ["proceed", "create"])
    }

    @Test func aLaterWorkspaceOfItsOwnIsTheAnchor() async throws {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "live"), generationChanged: false))
        store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-from-the-image"), name: "workspace-1"),
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 2), key: WorkspaceKey(rawValue: "ws-own"), name: "workspace-2"),
        ]))
        let id = try await CloudMachineWorkspace.existing(in: store, notConnected: Self.notConnected, listedElsewhere: { $0 == "ws-from-the-image" })
        #expect(id == "ws-own")
    }

    @Test func aTreeThatArrivesAfterTheConnectionIsReadNotReplaced() async throws {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "first"), generationChanged: false))
        let read = Task { @MainActor in try await CloudMachineWorkspace.existing(in: store, notConnected: Self.notConnected) }
        await Task.yield()
        store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-existing"), name: "workspace-1"),
        ]))
        #expect(try await read.value == "ws-existing", "an empty list before the first tree made a second workspace")
    }

    /// After a resume the store still holds the last connection's tree: that list is not this
    /// connection's, so the read waits for the new tree (review finding).
    @Test func theLastConnectionsTreeIsNotReadAfterAReconnect() async throws {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "before"), generationChanged: false))
        store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "old"), name: "old-workspace"),
        ]))
        _ = store.apply(.disconnected(reason: "paused"))
        _ = store.apply(.connected(DaemonIdentity(generation: "resumed"), generationChanged: false))
        let read = Task { @MainActor in try await CloudMachineWorkspace.existing(in: store, notConnected: Self.notConnected) }
        await Task.yield()
        store.apply(snapshot: DaemonTree(registryID: "s-vm"))
        #expect(try await read.value == nil, "a stale nonempty tree must not suppress creation after live empty state")
    }

    @Test func liveEmptyTreeChecksProceedBeforeCreatingAndReportsCreation() async throws {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "before"), generationChanged: false))
        store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "old"), name: "old"),
        ]))
        _ = store.apply(.disconnected(reason: "paused"))
        _ = store.apply(.connected(DaemonIdentity(generation: "new"), generationChanged: false))
        var calls: [String] = []
        let read = Task { @MainActor in
            try await CloudMachineWorkspace.first(in: store, notConnected: Self.notConnected, beforeCreate: { calls.append("proceed") }) {
                calls.append("create")
                return "created"
            }
        }
        await Task.yield()
        #expect(calls.isEmpty)
        store.apply(snapshot: DaemonTree(registryID: "s-vm"))
        let result = try await read.value
        #expect(calls == ["proceed", "create"])
        #expect(result.id == "created")
        #expect(result.created, "terminalAnchor must not create again while this workspace's mirror is late")
        #expect(store.workspaces.isEmpty, "the creation result must not depend on its mirror arriving")
    }

    @Test func refusedProceedDoesNotCreateAfterReadingTheTree() async {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "live"), generationChanged: false))
        store.apply(snapshot: DaemonTree(registryID: "s-vm"))
        var created = false
        await #expect(throws: ActionFailure.self) {
            _ = try await CloudMachineWorkspace.first(in: store, notConnected: Self.notConnected, beforeCreate: { throw ActionFailure(message: "cancelled") }) {
                created = true
                return "unexpected"
            }
        }
        #expect(!created)
    }

    @Test func liveExistingWorkspaceDoesNotCheckProceedOrCreate() async throws {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "before"), generationChanged: false))
        store.apply(snapshot: DaemonTree(registryID: "s-vm"))
        _ = store.apply(.disconnected(reason: "paused"))
        _ = store.apply(.connected(DaemonIdentity(generation: "new"), generationChanged: false))
        let read = Task { @MainActor in
            try await CloudMachineWorkspace.first(in: store, notConnected: Self.notConnected, beforeCreate: { Issue.record("unexpected proceed") }) {
                Issue.record("unexpected create")
                return nil
            }
        }
        await Task.yield()
        store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "existing"), name: "existing"),
        ]))
        let result = try await read.value
        #expect(result.id == "existing")
        #expect(!result.created)
    }

    /// The daemon's connection is published before the store hears `.connected` (which moves the
    /// epoch): a read in that window still waits for the new connection's tree (review finding).
    @Test func aReadBeforeTheStoreHearsTheConnectionWaits() async throws {
        let store = DaemonStore()
        // A tree the store holds before any connection (the machine's launch snapshot): its epoch
        // is the store's, so only the connected state tells it is not this connection's.
        store.apply(snapshot: DaemonTree(registryID: "s-vm"))
        let read = Task { @MainActor in try await CloudMachineWorkspace.existing(in: store, notConnected: Self.notConnected) }
        await Task.yield()
        _ = store.apply(.connected(DaemonIdentity(generation: "resumed"), generationChanged: false))
        store.apply(snapshot: DaemonTree(registryID: "s-vm", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "ws-made-meanwhile"), name: "workspace-1"),
        ]))
        #expect(try await read.value == "ws-made-meanwhile", "a read before the store heard the connection took the old list")
    }

    /// A tree that never comes is not "none": the read throws instead of letting the open make a
    /// workspace on a machine whose list it never saw (review finding).
    @Test func aTreeThatNeverComesThrowsInsteadOfNone() async {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(registryID: "s-vm"))
        await #expect(throws: ActionFailure.self) { _ = try await CloudMachineWorkspace.existing(in: store, within: .milliseconds(50), notConnected: Self.notConnected) }
    }

    @Test func aLoadedEmptyTreeHasNone() async throws {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(generation: "live"), generationChanged: false))
        store.apply(snapshot: DaemonTree(registryID: "s-vm"))
        #expect(try await CloudMachineWorkspace.existing(in: store, notConnected: Self.notConnected) == nil)
    }
}
