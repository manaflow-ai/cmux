@testable import CmuxNextAgentPane
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextApp

/// cx-ckt2z: a chat started from a prewarmed New Tab page (the spare a tab adopts) refused
/// `tab.open` and `tab.typeAhead` once it became a chat, while a chat in a tab made without the
/// spare answers them. A chat outside any tab (Start Agent's panel, onboarding) still refuses them.
@MainActor
struct SpareNewTabChatOpensTabsTests {
    private static let host = "install:this-mac"

    /// The tabs' page: a loopback dev server origin (Debug), so views are made without the bundle.
    private static func agentTabs() -> AgentTabStore {
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(), environment: environment, showcase: true)
        tabs.localHost = host
        return tabs
    }

    /// One pane holding a New Tab page of this Mac (a blank chat record, no session yet).
    private static func store() -> DaemonStore {
        let store = DaemonStore()
        var page = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        page.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [page])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return store
    }

    private static func handler(_ opened: @escaping (AgentPaneOpenTab) -> Void) -> NewTabPageHandler {
        NewTabPageHandler(open: { _, request in opened(request) }, jump: { _, _ in }, editShortcut: { _ in })
    }

    private static var open: AgentPaneRequest { AgentPaneRequest(body: ["method": "tab.open", "params": ["kind": "terminal", "text": "ls"]]) }
    private static var typeAhead: AgentPaneRequest { AgentPaneRequest(body: ["method": "tab.typeAhead", "params": ["text": "!ls"]]) }

    @Test func aChatFromThePrewarmedNewTabPageStillOpensTabs() async throws {
        let store = Self.store()
        let tabs = Self.agentTabs()
        try #require(tabs.canHostChat, "no agent page source")
        tabs.lookup = { key in store.tab(id: key)?.agentSession.map { ($0, store) } }
        var opened: [AgentPaneOpenTab] = []
        tabs.firstPageNewTab = { _, _, _ in (AgentPaneNewTab(kind: .agent), Self.handler { opened.append($0) }) }
        tabs.blankChatHandler = { _ in Self.handler { opened.append($0) } }
        let spare = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)))
        tabs.takeSpare = { spare }
        let key = try #require(store.tab(surface: 1)?.id)

        // The New Tab page made for the tab adopts the prewarmed spare (cx-ec99).
        let view = try #require(tabs.view(for: key))
        #expect(view === spare, "the tab's page is not the spare")
        view.model.transport.gestures.record()  // the person's Return (cx-hnpxh)
        #expect(await view.model.respond(to: Self.open)["ok"] as? Bool == true, "the New Tab page refused tab.open")

        // Its first send makes it a chat; the chat in this tab still opens tabs and types ahead.
        _ = await view.model.respond(to: AgentPaneRequest(body: ["method": "chat.persistSession", "params": ["sessionId": "s-ckt2z"]]))
        #expect(view.model.newTab == nil, "the page did not become a chat")
        view.model.transport.gestures.record()  // the person's Return (cx-hnpxh)
        #expect(await view.model.respond(to: Self.open)["ok"] as? Bool == true, "the chat from the spare refused tab.open")
        #expect(await view.model.respond(to: Self.typeAhead)["ok"] as? Bool == true, "the chat from the spare refused tab.typeAhead")
        #expect(opened.count == 2, "\(opened)")
    }

    /// A chat outside any tab has no tab to convert: it refuses both, even with handlers set.
    @Test func aStandaloneChatStillRefusesTabOpen() async throws {
        let tabs = Self.agentTabs()
        let view = try #require(tabs.standaloneView(seed: AgentPaneSeed(cwd: "/tmp")))
        var opened = 0
        view.model.onOpenTab = { _ in opened += 1 }
        view.model.onTypeAhead = { _ in opened += 1 }
        #expect(await view.model.respond(to: Self.open)["ok"] as? Bool != true)
        #expect(await view.model.respond(to: Self.typeAhead)["ok"] as? Bool != true)
        #expect(opened == 0)
    }
}
