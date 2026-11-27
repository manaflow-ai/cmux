import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A Cloud chat's prompt goes as `handoff-<turn>-<id>` (``AgentPaneHandoffPrompt``): the turn is a
/// label on the same prompt, so a gesture ticket bound to its own id still allows it, once, and no
/// other prompt.
@Suite(.serialized)
@MainActor
struct AgentPaneHandoffPromptTests {
    private func prompt(_ promptId: String) -> AgentPaneGesturePick {
        AgentPaneGesturePick(method: "session/prompt", params: ["_meta": ["acpmux": ["promptId": promptId]]])
    }

    @Test func theOwnIdDropsOnlyAHandoffTurnsLabel() {
        #expect(AgentPaneHandoffPrompt(id: "handoff-3-0b6f2c4e-1d2a").ownID == "0b6f2c4e-1d2a")
        #expect(AgentPaneHandoffPrompt(id: "handoff-123456789012345-p").ownID == "p")
        // Not a turn acpmux reads: kept as it is.
        for id in ["p-1", "handoff-1-handoff-2-p", "handoff-0-p", "handoff-01-p", "handoff--p", "handoff-3-", "handoff-x-p", "handoff-1234567890123456-p", "handoff-3"] {
            #expect(AgentPaneHandoffPrompt(id: id).ownID == id, "\(id)")
        }
    }

    @Test func aPromptsPickIsItsOwnIdUnderTheLabel() {
        #expect(prompt("handoff-2-p-1") == prompt("p-1"))
        #expect(prompt("handoff-2-p-1") != prompt("p-2"))
        // One label only: a ticket for a labelled id never allows the id under a second label.
        #expect(prompt("handoff-1-handoff-2-p-1") != prompt("handoff-2-p-1"))
    }

    @Test func aSeededPromptsTicketAllowsItUnderAHandoffTurnOnce() {
        let gestures = AgentPaneUserGestures(now: { 1000 })
        let seed = gestures.issueSeedTicket()
        #expect(gestures.redeem(seed.ticket, connection: 1, pick: prompt("handoff-1-" + seed.promptId)))
        #expect(!gestures.redeem(seed.ticket, connection: 1, pick: prompt("handoff-1-" + seed.promptId)))
    }

    @Test func aSendsTicketAllowsOnlyItsOwnPrompt() throws {
        let gestures = AgentPaneUserGestures(now: { 1000 })
        gestures.record()
        let intent = try #require(AgentPaneGestureIntent(gestureParams: ["intent": ["method": "session/prompt", "params": ["promptId": "p-1"]]]))
        let ticket = try #require(gestures.reserve(connection: 1, intent: intent))
        #expect(!gestures.redeem(ticket, connection: 1, pick: prompt("handoff-4-p-2")))
        gestures.record()
        let again = try #require(gestures.reserve(connection: 1, intent: intent))
        #expect(gestures.redeem(again, connection: 1, pick: prompt("handoff-4-p-1")))
    }

    /// A Retry keeps the id its prompt went with, so a trust refusal's hold for a labelled prompt
    /// reserves under the label (App.tsx's failed-row Trust): Trust's resend under that same id
    /// redeems it, once, and a ticket under one label never allows the id under two.
    @Test func aTicketReservedUnderTheLabelAllowsItsResend() throws {
        let gestures = AgentPaneUserGestures(now: { 1000 })
        gestures.record()
        let held = try #require(AgentPaneGestureIntent(gestureParams: ["intent": ["method": "session/prompt", "params": ["promptId": "handoff-2-p-1"]]]))
        #expect(held.params == ["promptId": .string("p-1")])
        let ticket = try #require(gestures.reserve(connection: 1, intent: held))
        #expect(!gestures.redeem(ticket, connection: 1, pick: prompt("handoff-1-handoff-2-p-1")))
        gestures.record()
        let again = try #require(gestures.reserve(connection: 1, intent: held))
        #expect(gestures.redeem(again, connection: 1, pick: prompt("handoff-2-p-1")))
        #expect(!gestures.redeem(again, connection: 1, pick: prompt("handoff-2-p-1")))
    }

    @Test func theAskNamesTheStoresSessionIdsOnly() {
        #expect(AgentPaneRequest(body: ["method": "cloud.handoffTurn", "params": ["sessionId": "019a-ab_c.d:e"]]) == .cloudHandoffTurn(sessionId: "019a-ab_c.d:e"))
        #expect(AgentPaneRequest(body: ["method": "cloud.handoffTurn", "params": ["sessionId": "a b"]]) == .unsupported("cloud.handoffTurn"))
        #expect(AgentPaneRequest(body: ["method": "cloud.handoffTurn", "params": [String: Any]()]) == .unsupported("cloud.handoffTurn"))
    }
}
