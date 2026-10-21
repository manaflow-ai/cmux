@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The New Tab import cards' button: the page posts `importCards.act {id, action}`; only a short
/// card id and a lowercase action word reach the App.
@MainActor
struct AgentPaneImportCardsTests {
    @Test func aCardButtonDecodesAndAMalformedOneIsRefused() {
        #expect(AgentPaneRequest(body: ["method": "importCards.act", "params": ["id": "browser.chrome", "action": "start"]])
            == .importCard(AgentPaneImportCards.Act(["id": "browser.chrome", "action": "start"])!))
        for params: [String: Any] in [
            [:],
            ["id": "browser.chrome"],
            ["id": "", "action": "start"],
            ["id": String(repeating: "x", count: 201), "action": "start"],
            ["id": "browser.chrome", "action": "Start"],
            ["id": "browser.chrome", "action": "start now"],
            ["id": "browser.chrome", "action": "émettre"],
            ["id": "browser.chrome", "action": String(repeating: "a", count: 17)],
            ["id": 3, "action": "start"],
        ] {
            #expect(AgentPaneRequest(body: ["method": "importCards.act", "params": params]) == .unsupported("importCards.act"))
        }
        #expect(AgentPageOps.all.contains(AgentPageOps.namespace + "importCards.act"))
    }

    @Test func aButtonRunsOnlyOnceTheAppWiredTheCards() {
        let cards = AgentPaneImportCards()
        let act = AgentPaneImportCards.Act(["id": "agents.codex", "action": "dismiss"])!
        #expect(!cards.perform(act))
        var pressed: [String] = []
        cards.onAction = { id, action in pressed.append("\(id) \(action)") }
        #expect(cards.perform(act))
        #expect(pressed == ["agents.codex dismiss"])
    }
}
