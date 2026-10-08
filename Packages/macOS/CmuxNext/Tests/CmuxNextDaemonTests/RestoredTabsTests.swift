import Foundation
import Testing
@testable import CmuxNextDaemon

/// Which tabs a connection found already there (restored at launch or after
/// a daemon restart), for page history: their reload is not a visit, and a
/// tab created after the first snapshot (by the app, a script or the CLI)
/// always records its first visit (plans/cmux-next/history.md 2, `page`).
@MainActor @Suite struct RestoredTabsTests {
    private static func identity() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","version":"0.1.0","protocol":12,"capabilities":[],"session":"t","pid":1,"registry_id":"r","generation":"A","workspace_revision":0}"#
        return try WireCoding.decoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    private static func tabIDs(_ store: DaemonStore) -> Set<String> {
        Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
    }

    @Test func onlyTheFirstSnapshotOfAConnectionCountsAsRestored() throws {
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        let store = DaemonStore()
        store.apply(.connected(try Self.identity(), generationChanged: false))
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: []))
        #expect(store.restoredTabIDs.isEmpty)
        // Tabs that appear later in the same connection were created now.
        store.apply(snapshot: tree)
        #expect(!Self.tabIDs(store).isEmpty)
        #expect(store.restoredTabIDs.isEmpty)
        // A new connection (daemon restart, relaunch) finds them restored.
        store.apply(.disconnected(reason: "eof"))
        store.apply(.connected(try Self.identity(), generationChanged: true))
        store.apply(snapshot: tree)
        #expect(store.restoredTabIDs == Self.tabIDs(store))
    }
}
