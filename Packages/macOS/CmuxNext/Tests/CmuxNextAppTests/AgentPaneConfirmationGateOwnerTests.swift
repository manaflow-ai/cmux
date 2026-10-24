@testable import CmuxNextAgentPane
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextApp

/// One native mode confirmation open in the whole app: the agent tab store holds the one gate
/// (``AgentTabStore/confirmationGate``) and passes it to the transport of every pane it makes (a
/// tab's page, a prewarmed spare, a chat outside any tab), so every pane asks through it, so a second pane's ask is refused while one is open. A
/// second store (a test's) has its own gate.
@MainActor
struct AgentPaneConfirmationGateOwnerTests {
    /// The tabs' page: a loopback dev server origin (Debug), so views are made without the bundle.
    private static func agentTabs() -> AgentTabStore {
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(), environment: environment, showcase: true)
        tabs.localHost = "install:this-mac"
        return tabs
    }

    @Test func everyPaneOfAStoreAsksThroughItsOneGate() throws {
        let tabs = Self.agentTabs()
        try #require(tabs.canHostChat, "no agent page source")
        let spare = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)))
        let chat = try #require(tabs.standaloneView(seed: AgentPaneSeed(cwd: "/tmp")))
        #expect(spare.model.transport.confirmationGate === tabs.confirmationGate)
        #expect(chat.model.transport.confirmationGate === tabs.confirmationGate)

        // A confirmation open in one pane refuses the other's until it closes.
        #expect(spare.model.transport.confirmationGate.open())
        #expect(!chat.model.transport.confirmationGate.open(), "a second pane opened a second confirmation")
        spare.model.transport.confirmationGate.close()
        #expect(chat.model.transport.confirmationGate.open())
        chat.model.transport.confirmationGate.close()
    }

    /// A tab's page (``AgentTabStore/view(for:)``, here an opened chat of this Mac) asks through
    /// the same gate as the store's spare.
    @Test func aTabsPageAsksThroughTheStoresGate() throws {
        let host = "install:this-mac"
        let store = DaemonStore()
        var tab = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: "s-open"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        store.connectionState = .connected(DaemonIdentity(generation: DaemonGeneration(rawValue: "gate-owner-test")))
        let tabs = Self.agentTabs()
        try #require(tabs.canHostChat, "no agent page source")
        tabs.lookup = { key in store.tab(id: key)?.agentSession.map { ($0, store) } }
        let key = try #require(store.tab(surface: 1)?.id)
        let page = try #require(tabs.view(for: key))
        let spare = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)))
        #expect(page.model.transport.confirmationGate === tabs.confirmationGate)

        #expect(page.model.transport.confirmationGate.open())
        #expect(!spare.model.transport.confirmationGate.open(), "a spare opened a second confirmation beside a tab's")
        page.model.transport.confirmationGate.close()
    }

    @Test func anotherStoreHasItsOwnGate() throws {
        let tabs = Self.agentTabs(), other = Self.agentTabs()
        try #require(tabs.canHostChat, "no agent page source")
        let pane = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)))
        let otherPane = try #require(other.makeSpare(AgentPaneNewTab(kind: .agent)))
        #expect(pane.model.transport.confirmationGate.open())
        #expect(otherPane.model.transport.confirmationGate.open(), "two stores shared one gate")
        pane.model.transport.confirmationGate.close()
        otherPane.model.transport.confirmationGate.close()
    }
}
