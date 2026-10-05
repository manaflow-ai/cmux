import Foundation
import Testing
@testable import CmuxNextDaemon

/// A create intent (an agent chat tab, R81 zero wait): its provisional tab shows at the end of
/// the pane at once, survives a snapshot that predates it, and leaves in the same step the
/// daemon's tab arrives (settled) or when the creation fails (rejected).
@MainActor @Suite struct IntentCreateTabTests {
    private func provisional() -> TabSnapshot {
        let provisional = ProvisionalTab()
        var tab = TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.id),
                              kind: .conversation, title: "about:blank", browserRenderer: "frontend")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:mac"))
        return tab
    }

    private func loaded() throws -> (DaemonStore, DaemonTree, PaneModel) {
        let store = DaemonStore()
        let tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        store.apply(snapshot: tree)
        let pane = try #require(store.workspaces.first?.screens.first?.panes.first)
        return (store, tree, pane)
    }

    @Test func theProvisionalTabShowsUntilTheDaemonsTabReplacesIt() throws {
        let (store, tree, pane) = try loaded()
        let before = Self.ids(store)
        let tab = provisional()
        store.intend(.createTab(pane: pane.handle, provisional: tab), transaction: "tx")
        #expect(Self.ids(store) == before + [Self.id(tab)])
        #expect(store.tab(surface: tab.surface)?.agentSession?.host == "install:mac")
        // A snapshot that predates the creation keeps it shown.
        store.apply(snapshot: tree)
        #expect(Self.ids(store) == before + [Self.id(tab)])
        // The daemon's tab arrives and the reply's sequence is reached: one step, no provisional.
        var created = tree
        var real = TabSnapshot(surface: 900, tabResourceID: ResourceID(rawValue: "tab_real"), kind: .conversation,
                               title: "about:blank", browserRenderer: "frontend")
        real.conversation = tab.conversation
        created.workspaces[0].screens[0].panes[0].tabs.append(real)
        store.apply(snapshot: created)
        store.noteSettled("tx", at: 0)
        #expect(Self.ids(store) == before + ["tab_real"])
        #expect(store.tab(surface: tab.surface) == nil)
        #expect(store.mirrorViolations.isEmpty)
    }

    @Test func aRejectedCreationRemovesTheProvisionalTab() throws {
        let (store, _, pane) = try loaded()
        let before = Self.ids(store)
        let tab = provisional()
        store.intend(.createTab(pane: pane.handle, provisional: tab), transaction: "tx")
        store.rejectIntent("tx")
        #expect(Self.ids(store) == before)
        #expect(store.tab(surface: tab.surface) == nil)
        #expect(store.mirrorViolations.isEmpty)
    }

    private static func ids(_ store: DaemonStore) -> [String] {
        store.workspaces.first?.screens.first?.panes.first?.tabs.map(\.id) ?? []
    }

    private static func id(_ tab: TabSnapshot) -> String { tab.tabResourceID?.rawValue ?? "" }
}

/// The daemon's tab can arrive before the creation's reply: once the reply names it, the
/// provisional tab goes at once, and a later snapshot never shows both.
@MainActor @Suite struct IntentCreateTabOrderTests {
    @Test func theReplyNamingAnArrivedTabRemovesTheProvisionalOne() throws {
        let store = DaemonStore()
        var tree = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        store.apply(snapshot: tree)
        let pane = try #require(store.workspaces.first?.screens.first?.panes.first)
        let provisional = ProvisionalTab()
        var tab = TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.id),
                              kind: .conversation, title: "about:blank", browserRenderer: "frontend")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:mac"))
        store.intend(.createTab(pane: pane.handle, provisional: tab), transaction: "tx")
        var real = tab
        real.surface = 901
        real.tabResourceID = ResourceID(rawValue: "tab_real")
        tree.workspaces[0].screens[0].panes[0].tabs.append(real)
        store.apply(snapshot: tree) // the tree event before the reply: both show for now
        ProvisionalTab.created("tx", surface: 901, in: store)
        let ids: [String] = store.workspaces.first?.screens.first?.panes.first?.tabs.map(\.id) ?? []
        #expect(!ids.contains(where: ProvisionalTab.isProvisional))
        #expect(ids.last == "tab_real")
        store.apply(snapshot: tree)
        let after: [String] = store.workspaces.first?.screens.first?.panes.first?.tabs.map(\.id) ?? []
        #expect(!after.contains(where: ProvisionalTab.isProvisional))
        #expect(store.mirrorViolations.isEmpty)
    }
}
