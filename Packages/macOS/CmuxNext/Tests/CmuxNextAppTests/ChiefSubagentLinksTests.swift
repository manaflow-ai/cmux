import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import Foundation
import Testing

/// Lawrence 2026-10-22: "why did u forget to link a459". Home links a bare subagent id in any
/// Chief's reply to that subagent's chat; the app reads the ids from the Chief home's acpmux lanes.
struct ChiefSubagentLinksTests {
    static func lane(_ name: String, id: String, peer: String? = nil, parent: String? = "optchat-chief:2e448bc2",
                     created: TimeInterval = 0) -> AgentActivityLane {
        AgentActivityLane(id: id, name: name, title: name, peer: peer, parent: parent, state: .working, since: nil,
                          error: nil, createdAt: Date(timeIntervalSince1970: created))
    }

    @Test func eachSubagentLaneLinksItsIdToItsChat() {
        let links = ChiefSubagentLinks.links(lanes: [
            Self.lane("optchat-sub-2e448bc2-a459", id: "01a161e0-f2df-7e21-83d4-fc229778848e"),
            Self.lane("optchat-sub-2e448bc2-a468", id: "s-468"),
            Self.lane("optchat-2e448bc2-9201", id: "turn"), // a turn, not a subagent
            Self.lane("optchat-compact-2e448bc2-1", id: "compact"),
        ])
        #expect(links == [
            "a459": "cmux://chief/2e448bc2/session/01a161e0-f2df-7e21-83d4-fc229778848e",
            "a468": "cmux://chief/2e448bc2/session/s-468",
        ])
    }

    @Test func aRestartedSubagentLinksItsNewestSession() {
        let links = ChiefSubagentLinks.links(lanes: [
            Self.lane("optchat-sub-2e448bc2-a466", id: "old", created: 10),
            Self.lane("optchat-sub-2e448bc2-a466-2", id: "new", created: 20),
        ])
        #expect(links["a466"] == "cmux://chief/2e448bc2/session/new")
    }

    @Test func aLaneWithoutAHomeOrWithABadSessionIdIsLeftOut() {
        let links = ChiefSubagentLinks.links(lanes: [
            Self.lane("optchat-sub-XYZ-a1", id: "s-1", parent: nil),
            Self.lane("optchat-sub-2e448bc2-a2", id: "bad id/with space"),
        ])
        #expect(links.isEmpty)
    }
}
