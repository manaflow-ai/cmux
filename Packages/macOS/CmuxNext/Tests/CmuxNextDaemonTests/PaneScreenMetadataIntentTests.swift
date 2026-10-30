import Foundation
import Testing
@testable import CmuxNextDaemon

/// Rename Pane, Rename Screen and a screen's color, icon and pin show in the input's turn (store
/// intents), stay through the daemon's snapshots until the reply settles them, and go back exactly
/// when the daemon refuses. Before, each was a plain `send`: nothing changed until the daemon's
/// echo arrived (one daemon round trip after the input, 50-660 ms under load; instant-new-surfaces.md).
@MainActor
struct PaneScreenMetadataIntentTests {
    nonisolated private static let pane = PaneID(rawValue: 10)
    nonisolated private static let screen = ScreenID(rawValue: 100)

    private static func tree(paneName: String? = "old", screenName: String? = "first", color: String? = nil,
                             icon: String? = nil, pinned: Bool = false) -> DaemonTree {
        DaemonTree(workspaceRevision: 1, workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1", screens: [
                ScreenSnapshot(id: screen, name: screenName, active: true, activePane: pane, layout: .leaf(pane),
                               panes: [PaneSnapshot(id: pane, name: paneName, tabs: [TabSnapshot(surface: 1)])],
                               color: color, icon: icon, pinned: pinned),
            ]),
        ])
    }

    private static func store() -> DaemonStore {
        let store = DaemonStore()
        store.apply(snapshot: tree())
        return store
    }

    private struct Shown: Equatable, Sendable {
        var paneName: String?
        var screenName: String?
        var color: String?
        var icon: String?
        var pinned: Bool
    }

    private static func shown(_ store: DaemonStore) -> Shown {
        let screen = store.screen(screen)
        return Shown(paneName: store.pane(pane)?.name, screenName: screen?.name, color: screen?.color, icon: screen?.icon,
                     pinned: screen?.pinned ?? false)
    }

    nonisolated private static let intents: [(Intent, Shown)] = [
        (.renamePane(pane: pane, name: "logs"), Shown(paneName: "logs", screenName: "first", color: nil, icon: nil, pinned: false)),
        (.renamePane(pane: pane, name: ""), Shown(paneName: nil, screenName: "first", color: nil, icon: nil, pinned: false)),
        (.renameScreen(screen: screen, name: "build"), Shown(paneName: "old", screenName: "build", color: nil, icon: nil, pinned: false)),
        (.setScreenColor(screen: screen, color: "red"), Shown(paneName: "old", screenName: "first", color: "red", icon: nil, pinned: false)),
        (.setScreenIcon(screen: screen, icon: "star"), Shown(paneName: "old", screenName: "first", color: nil, icon: "star", pinned: false)),
        (.setScreenPinned(screen: screen, pinned: true), Shown(paneName: "old", screenName: "first", color: nil, icon: nil, pinned: true)),
    ]

    @Test(arguments: 0..<intents.count)
    func theChangeShowsInTheInputsTurn(_ index: Int) {
        let (intent, expected) = Self.intents[index]
        let store = Self.store()
        store.intend(intent, transaction: .generate())
        #expect(Self.shown(store) == expected)
    }

    /// A daemon snapshot taken before the command applied does not undo what the person sees.
    @Test(arguments: 0..<intents.count)
    func anOlderSnapshotKeepsTheChange(_ index: Int) {
        let (intent, expected) = Self.intents[index]
        let store = Self.store()
        store.intend(intent, transaction: .generate())
        store.apply(snapshot: Self.tree())
        #expect(Self.shown(store) == expected)
    }

    /// A refusal puts every field back exactly.
    @Test(arguments: 0..<intents.count)
    func aRefusalPutsItBack(_ index: Int) {
        let store = Self.store()
        let before = Self.shown(store)
        let transaction = ClientTransactionID.generate()
        store.intend(Self.intents[index].0, transaction: transaction)
        store.rejectIntent(transaction)
        #expect(Self.shown(store) == before)
        #expect(store.pendingIntents.isEmpty)
    }
}
