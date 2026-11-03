import Testing
@testable import CmuxNextDaemon

/// #32989: a `cmux workspace create` (the resource API) names its create's idempotency key on the
/// workspace-added delta (`mutation_id`, origin `resource-api`). The store hands the App that key
/// for the new workspace before the membership hook runs, so the App files it into the window the
/// create was announced for, never into the most recent window first.
@MainActor
struct ResourceWorkspaceAddedHookTests {
    private static func workspace(_ number: Int) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(number)), key: WorkspaceKey(rawValue: "ws-\(number)"), name: "Workspace \(number)")
    }

    private static func loaded() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaceRevision: 10, workspaces: [workspace(1)]))
        return store
    }

    @Test func aResourceAPICreateNamesItsKeyBeforeTheMembershipHook() {
        let store = Self.loaded()
        var events: [String] = []
        store.onResourceWorkspaceAdded = { id, key in events.append("added \(id) \(key)") }
        store.onWorkspaceListChanged = { events.append("list") }
        store.apply(.workspaceAdded(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 2), index: 1, entity: Self.workspace(2),
                                                   workspaceRevision: 11, origin: DaemonStore.resourceAPIOrigin, mutationID: "cli-key-1")))
        #expect(events == ["added ws-2 cli-key-1", "list"])
    }

    /// A create with a terminal (the CLI's default) names `<key>/workspace` on its workspace: the key comes back.
    @Test func aTerminalCreateNamesItsKeyThroughTheReservationSuffix() {
        let store = Self.loaded()
        var added: [String] = []
        store.onResourceWorkspaceAdded = { _, key in added.append(key) }
        store.apply(.workspaceAdded(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 2), index: 1, entity: Self.workspace(2),
                                                   workspaceRevision: 11, origin: DaemonStore.resourceAPIOrigin,
                                                   mutationID: "cli-key-1" + DaemonStore.workspaceReservationSuffix)))
        #expect(added == ["cli-key-1"])
    }

    @Test func anotherOriginsCreateNamesNoKey() {
        let store = Self.loaded()
        var added: [String] = []
        store.onResourceWorkspaceAdded = { id, _ in added.append(id) }
        // The app's own create (its mutation ids are its own, not a CLI key) and a delta with no mutation.
        store.apply(.workspaceAdded(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 2), index: 1, entity: Self.workspace(2),
                                                   workspaceRevision: 11, origin: "cmux-next-app", mutationID: "app-key")))
        store.apply(.workspaceAdded(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 3), index: 2, entity: Self.workspace(3),
                                                   workspaceRevision: 12)))
        #expect(added.isEmpty)
    }

    @Test func aDeltaForAWorkspaceTheStoreHasNamesNoKey() {
        let store = Self.loaded()
        var added: [String] = []
        store.onResourceWorkspaceAdded = { id, _ in added.append(id) }
        store.apply(.workspaceAdded(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: 1), index: 0, entity: Self.workspace(1),
                                                   workspaceRevision: 11, origin: DaemonStore.resourceAPIOrigin, mutationID: "k")))
        #expect(added.isEmpty, "only a new workspace is placed")
    }
}
