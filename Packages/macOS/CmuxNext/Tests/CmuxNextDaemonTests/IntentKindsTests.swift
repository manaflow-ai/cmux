import Foundation
import Testing
@testable import CmuxNextDaemon

/// The intent kinds beyond tab moves (rename, pin, workspace order and
/// group, collapse) follow the same rule as moves: shown until settled by
/// echo, by the store reaching the reply's sequence, or by rejection.
@MainActor @Suite struct IntentKindsTests {
    private func loaded() throws -> (DaemonStore, DaemonTree) {
        let store = DaemonStore()
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        store.apply(snapshot: tree)
        return (store, tree)
    }

    /// The rename's reply came back (rename-tab echoes no transaction), but
    /// its `tab-changed` is not applied yet, and a resync that started
    /// before the reply lands with the old name. The rename is not settled,
    /// so it must stay visible; the legacy patch was dropped at "the next
    /// snapshot" and the old name showed until the event arrived.
    @Test func anUnsettledRenameSurvivesASnapshotThatPredatesIt() async throws {
        let (store, tree) = try loaded()
        try await store.perform(.renameTab(surface: 3, name: "renamed"), expectEcho: false) { _ in }
        store.apply(snapshot: tree)
        #expect(store.tab(surface: 3)?.name == "renamed")
    }
}
