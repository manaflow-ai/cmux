import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

@MainActor
struct AgentTabStoreTests {
    @Test func closingAPaneForgetsItsAgentTabsOnly() {
        let store = AgentTabStore(tag: nil, environment: ["CMUX_NEXT_AGENT_PANE_MOCK": "1"])
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
        let store = AgentTabStore(tag: nil, environment: Self.mock)
        let key = store.open(in: pane.id, of: daemon)

        _ = daemon.apply(.disconnected("test"))
        await ReopenClosedTabTests.settle { false }
        #expect(store.tabIDs(in: pane.id) == [key], "a daemon that is away keeps its panes' agent tabs")

        try Self.connect(daemon)
        let empty = #"{"workspace_revision":2,"generation":"GEN","registry_id":"r","workspaces":[]}"#
        daemon.apply(snapshot: try JSONDecoder().decode(DaemonTree.self, from: Data(empty.utf8)))
        await ReopenClosedTabTests.settle { store.tabIDs(in: pane.id).isEmpty }
        #expect(store.tabIDs(in: pane.id).isEmpty)
    }

    /// Duplicate Tab on an agent tab opened an empty chat.
    @Test func duplicatingAnAgentTabShowsTheSameSession() async throws {
        let daemon = DaemonStore()
        let store = AgentTabStore(tag: nil, environment: Self.mock)
        let key = store.open(in: "a", of: daemon)
        let view = try #require(store.view(for: key))
        _ = await view.model.respond(to: .persistSession("s-1"))
        let copy = store.duplicate(key, in: "a", of: daemon)
        #expect(store.tabIDs(in: "a") == [key, copy])
        #expect(store.view(for: copy)?.model.sessionId == "s-1")
        store.closePane("a")
    }
}
