@testable import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Testing

/// Needs you's marked tabs (tab-attention-v1): the page gets `{kind: "tab", tabId, reason,
/// workspaceTitle, tabTitle, atMs}` entries, and its Go to (`chat.attention.open {tabId}`) shows
/// only a tab it was listed, through the App's user jump.
@MainActor
struct AgentPaneAttentionTabsTests {
    let item = AgentPaneAttentionTabs.Item(tabId: "tab_1", reason: "Log in to GitHub", workspaceTitle: "cmux next",
                                           tabTitle: "GitHub · Sign in", atMs: 1_792_656_705_000)

    @Test func goToDecodesAndAMalformedOneIsRefused() {
        #expect(AgentPaneRequest(body: ["method": "chat.attention.open", "params": ["tabId": "tab_1"]]) == .attentionOpen("tab_1"))
        for params: [String: Any] in [[:], ["tabId": ""], ["tabId": 3], ["tabId": String(repeating: "x", count: 257)]] {
            #expect(AgentPaneRequest(body: ["method": "chat.attention.open", "params": params]) == .unsupported("chat.attention.open"))
        }
        #expect(AgentPageOps.all.contains(AgentPageOps.namespace + "chat.attention.open"))
    }

    @Test func thePageGetsEachMarkedTabByItsTitles() {
        let event = AgentPageEvent.attentionTabs([item])
        #expect(event.kind == "attentionTabs")
        #expect(event.value == .array([[
            "kind": "tab", "tabId": "tab_1", "reason": "Log in to GitHub", "workspaceTitle": "cmux next",
            "tabTitle": "GitHub · Sign in", "atMs": .number(1_792_656_705_000),
        ]]))
        #expect(AgentPageEvent.attentionTabs([]).value == .array([]))
    }

    @Test func goToShowsOnlyAListedTabAndOnlyOnceTheAppWiredIt() {
        let tabs = AgentPaneAttentionTabs()
        tabs.items = [item]
        #expect(!tabs.open("tab_1"), "no jump before the App wires one")
        var shown: [String] = []
        tabs.onOpen = { id in shown.append(id); return true }
        #expect(!tabs.open("tab_2"), "a tab the page was never shown")
        #expect(tabs.open("tab_1"))
        #expect(shown == ["tab_1"])
        tabs.items = []
        #expect(!tabs.open("tab_1"), "a cleared mark")
        #expect(shown == ["tab_1"])
    }

    @Test func eachChangeIsHeardOnce() {
        let tabs = AgentPaneAttentionTabs()
        var heard = 0
        tabs.onChange = { heard += 1 }
        tabs.items = [item]
        tabs.items = [item]
        #expect(heard == 1, "the same list again is no change")
        tabs.items = []
        #expect(heard == 2)
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A page's Go to moves the person's focus, so it needs their own click or key in the pane:
    /// page script alone (an agent's chat content) cannot show a tab.
    @Test func aPagesGoToNeedsThePersonsGesture() async {
        let shared = AgentPaneAttentionTabs.shared
        let (items, onOpen) = (shared.items, shared.onOpen)
        defer { shared.items = items; shared.onOpen = onOpen }
        var shown: [String] = []
        shared.items = [item]
        shared.onOpen = { id in shown.append(id); return true }
        let model = AgentPaneModel(host: NoHost())
        let request = AgentPaneRequest(body: ["method": "chat.attention.open", "params": ["tabId": "tab_1"]])
        let unasked = await model.respond(to: request)
        #expect((unasked["error"] as? [String: Any])?["code"] as? String == AgentPaneTransportError.gestureRequired.rawValue)
        #expect(shown.isEmpty, "a page with no gesture showed a tab")
        model.transport.gestures.record(click: true)
        let clicked = await model.respond(to: request)
        #expect(clicked["error"] == nil)
        #expect(shown == ["tab_1"])
    }
}
