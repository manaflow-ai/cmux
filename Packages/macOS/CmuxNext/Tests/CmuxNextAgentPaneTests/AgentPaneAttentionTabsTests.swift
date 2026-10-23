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
}
