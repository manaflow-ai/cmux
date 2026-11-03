import Foundation
import Testing
@testable import CmuxNextDaemon

/// A workspace's color shows in the input's turn (a store intent), stays through the daemon's
/// snapshots until the reply settles it, and goes back exactly when the daemon refuses
/// (https://github.com/manaflow-ai/cmux/issues/25657). Before, the sidebar painted the row once
/// but the store kept the old color, so the next live row recompute showed it again until the
/// daemon's echo arrived, 1-2 s later.
@MainActor
struct WorkspaceColorIntentTests {
    nonisolated private static let key = WorkspaceKey(rawValue: "w1")

    private static func tree(color: String? = "blue") -> DaemonTree {
        DaemonTree(workspaceRevision: 1, workspaces: [
            WorkspaceSnapshot(id: 1, key: key, name: "workspace-1", color: color),
        ])
    }

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: tree())
        return store
    }

    private static func color(_ store: DaemonStore) -> String? {
        store.workspacesByKey[key]?.color
    }

    nonisolated private static let colors: [String?] = ["red", nil]

    @Test(arguments: colors)
    func theColorShowsInTheInputsTurn(_ color: String?) {
        let store = Self.store()
        store.intend(.setWorkspaceColor(key: Self.key, color: color), transaction: .generate())
        #expect(Self.color(store) == color)
    }

    /// A daemon snapshot taken before the command applied does not bring the old color back.
    @Test(arguments: colors)
    func anOlderSnapshotKeepsTheColor(_ color: String?) {
        let store = Self.store()
        store.intend(.setWorkspaceColor(key: Self.key, color: color), transaction: .generate())
        store.apply(snapshot: Self.tree())
        #expect(Self.color(store) == color)
    }

    /// A refusal puts the old color back exactly.
    @Test(arguments: colors)
    func aRefusalPutsItBack(_ color: String?) {
        let store = Self.store()
        let transaction = ClientTransactionID.generate()
        store.intend(.setWorkspaceColor(key: Self.key, color: color), transaction: transaction)
        store.rejectIntent(transaction)
        #expect(Self.color(store) == "blue")
        #expect(store.pendingIntents.isEmpty)
    }

    /// The daemon's snapshot with the new color settles it: the color stays, the log empties.
    @Test func theDaemonsColorSettlesIt() {
        let store = Self.store()
        let transaction = ClientTransactionID.generate()
        store.intend(.setWorkspaceColor(key: Self.key, color: "red"), transaction: transaction)
        store.apply(snapshot: Self.tree(color: "red"))
        store.noteSettledAtNextSnapshot(transaction)
        store.apply(snapshot: Self.tree(color: "red"))
        #expect(Self.color(store) == "red")
        #expect(store.pendingIntents.isEmpty)
    }
}
