import Foundation
import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// Which tab opening an existing chat adopts the prewarmed New Tab page, and when that page may
/// serve one (CmuxNextApp's SpareSessionAdoptionTests drive the tab store end to end).
@Suite
struct AgentPaneSpareAdoptionTests {
    /// HQ#5914 finding 1, review of #27759: a spare whose client is still connecting is not taken
    /// for an existing chat (the open would wait behind its chat list), nor in Low Power Mode or
    /// at serious thermal state (each open would make another page).
    @Test func whichSpareServesAChat() {
        func serves(handshake: Bool = true, painted: Bool = true, clientReady: Bool = true, lowPower: Bool = false,
                    thermal: ProcessInfo.ThermalState = .nominal) -> Bool {
            AgentPaneSpareReadiness(handshake: handshake, painted: painted, clientReady: clientReady,
                                    lowPower: lowPower, thermal: thermal).servesChat
        }
        #expect(serves())
        #expect(serves(thermal: .fair))
        #expect(!serves(handshake: false))
        #expect(!serves(painted: false))
        #expect(!serves(clientReady: false))
        #expect(!serves(lowPower: true))
        #expect(!serves(thermal: .serious))
        #expect(!serves(thermal: .critical))
    }

    /// Only a chat of this Mac's acpmux with a session, and nothing its own handshake must carry.
    @Test func theDecision() {
        func adopts(thisMac: Bool = true, session: String? = "s", newTabPage: Bool = false,
                    seeded: Bool = false, wake: Bool = false, chief: Bool = false) -> String? {
            AgentPaneSpareAdoption(thisMac: thisMac, session: session, newTabPage: newTabPage, seeded: seeded, wake: wake)
                .adopted(chiefKeeps: { _ in chief })
        }
        #expect(adopts() == "s")
        // Another machine's chat, or a Chief home's (the App's `AgentPaneHostKind` .remote, .chief).
        #expect(adopts(thisMac: false) == nil)
        #expect(adopts(session: nil) == nil)
        #expect(adopts(session: "") == nil)
        #expect(adopts(newTabPage: true) == nil)
        #expect(adopts(seeded: true) == nil)
        #expect(adopts(wake: true) == nil)
        #expect(adopts(chief: true) == nil)
    }

    /// Leo, 2026-11-05: "things just don't f***ing open up fast enough on the right. / links.
    /// subagents. all". A subagent's pane takes the prewarmed page when the host holds its chat's
    /// tail (the chat hands it over as it asks for the pane), which the page draws in its adopt
    /// event's own render, so it never shows the empty transcript HQ#5914 found. Any other existing
    /// chat still opens cold while ``AgentPaneSpareReadiness/adoptsExistingChats`` is off.
    @Test func aSubagentPaneWithItsChatsTailTakesTheSpare() {
        #expect(AgentPaneSpareReadiness.adopts(subagentPane: true, keptTail: true))
        #expect(!AgentPaneSpareReadiness.adopts(subagentPane: true, keptTail: false))
        #expect(!AgentPaneSpareReadiness.adopts(subagentPane: false, keptTail: true))
        #expect(!AgentPaneSpareReadiness.adopts(subagentPane: false, keptTail: false))
    }

    /// The adopt event carries the chat's kept tail, so the page draws it in the event's own render
    /// instead of asking the host for it (`chat.tail.get`, a round trip raced against 250 ms that a
    /// busy main thread loses, leaving the pane empty until acpmux's attach answers).
    @Test func theAdoptEventCarriesTheChatsTail() throws {
        let tail: JSONValue = .object(["events": .array([.object(["seq": .number(1), "kind": .string("user_message")])]),
                                       "historyExhausted": .bool(true)])
        let text = AgentPaneView.adoptEventDetail(session: "s-1", revealTurn: "subagent:a", tail: tail)
        let detail = try #require(JSONValue(foundation: try JSONSerialization.jsonObject(with: Data(text.utf8))))
        #expect(detail["sessionId"] == .string("s-1"))
        #expect(detail["revealTurn"] == .string("subagent:a"))
        #expect(detail["tail"] == tail)
        // No tail kept: the detail names none, and the page asks the host as before.
        let bare = AgentPaneView.adoptEventDetail(session: "s-1", revealTurn: nil, tail: nil)
        let parsed = try #require(JSONValue(foundation: try JSONSerialization.jsonObject(with: Data(bare.utf8))))
        #expect(parsed == .object(["sessionId": .string("s-1")]))
    }
}
