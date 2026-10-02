import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

@MainActor
struct AgentTabStoreTests {
    @Test func closingAPaneForgetsItsAgentTabsOnly() {
        let store = AgentTabStore(tag: nil, registry: ActionRegistry.standard(), environment: ["CMUX_NEXT_AGENT_PANE_MOCK": "1"])
        let daemon = DaemonStore()
        _ = store.open(in: "a", of: daemon)
        _ = store.open(in: "a", of: daemon)
        let kept = store.open(in: "b", of: daemon)
        store.closePane("a")
        #expect(store.tabIDs(in: "a").isEmpty)
        #expect(store.tabIDs(in: "b") == [kept])
    }
}

@MainActor
struct AgentTabLifecycleTests {
    private static let mock = ["CMUX_NEXT_AGENT_PANE_MOCK": "1"]

    private static func connect(_ daemon: DaemonStore) throws {
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(ReopenClosedTabTests.identify.utf8))
        _ = daemon.apply(.connected(identity, generationChanged: false))
    }

    /// A pane can close while its window shows another workspace or while
    /// the daemon is away; no pane controller tears down then, and its agent
    /// tabs stayed in the store for the rest of the session.
    @Test func aPaneTheDaemonNoLongerListsClosesItsAgentTabs() async throws {
        let daemon = DaemonStore()
        try Self.connect(daemon)
        daemon.apply(snapshot: try ReopenClosedTabTests.tree([ReopenClosedTabTests.tab(1, "a", cwd: "/tmp")]))
        let pane = try #require(daemon.workspaces.first?.screens.first?.panes.first)
        let store = AgentTabStore(tag: nil, registry: ActionRegistry.standard(), environment: Self.mock)
        let key = store.open(in: pane.id, of: daemon)

        // A tree that drops the pane while the daemon is away is not
        // trusted; the tabs wait for the daemon to be back.
        _ = daemon.apply(.disconnected(reason: "test"))
        let empty = #"{"workspace_revision":2,"generation":"GEN","registry_id":"r","workspaces":[]}"#
        daemon.apply(snapshot: try JSONDecoder().decode(DaemonTree.self, from: Data(empty.utf8)))
        await ReopenClosedTabTests.settle { false }
        store.closeGonePanes(in: daemon)
        #expect(store.tabIDs(in: pane.id) == [key], "a daemon that is away keeps its panes' agent tabs")

        try Self.connect(daemon)
        await ReopenClosedTabTests.settle { store.tabIDs(in: pane.id).isEmpty }
        #expect(store.tabIDs(in: pane.id).isEmpty)
    }

    /// Duplicate Tab on an agent tab opened an empty chat.
    @Test func duplicatingAnAgentTabShowsTheSameSession() async throws {
        let daemon = DaemonStore()
        let store = AgentTabStore(tag: nil, registry: ActionRegistry.standard(), environment: Self.mock)
        let key = store.open(in: "a", of: daemon)
        let next = store.open(in: "a", of: daemon)
        let view = try #require(store.view(for: key))
        _ = await view.model.respond(to: .persistSession("s-1"))
        let copy = store.duplicate(key, in: "a", of: daemon)
        #expect(store.tabIDs(in: "a") == [key, copy, next])
        #expect(store.view(for: copy)?.model.sessionId == "s-1")
        store.closePane("a")
    }

    /// Pages show the app's shortcuts as bound now: a rebind in Settings or
    /// cmux.json reaches a page that is already open.
    @Test func openPagesFollowShortcutRebinds() async throws {
        let registry = ActionRegistry.standard()
        let store = AgentTabStore(tag: nil, registry: registry, environment: Self.mock)
        let key = store.open(in: "a", of: DaemonStore())
        let view = try #require(store.view(for: key))
        await ReopenClosedTabTests.settle { view.shortcuts.labels["agentPane.searchChats"] == "⌘K" }
        #expect(view.shortcuts.labels["agentPane.searchChats"] == "⌘K")
        registry.setShortcutOverride(Shortcut("j", modifiers: [.command, .option]), for: "agentPane.searchChats")
        await ReopenClosedTabTests.settle { view.shortcuts.labels["agentPane.searchChats"] == "⌥⌘J" }
        #expect(view.shortcuts.labels["agentPane.searchChats"] == "⌥⌘J")
        registry.setShortcutOverride(nil, for: "agentPane.searchChats")
        await ReopenClosedTabTests.settle { view.shortcuts.labels["agentPane.searchChats"] == nil }
        #expect(view.shortcuts.labels["agentPane.searchChats"] == nil, "an unbound action shows no shortcut")
        store.closePane("a")
    }
}
