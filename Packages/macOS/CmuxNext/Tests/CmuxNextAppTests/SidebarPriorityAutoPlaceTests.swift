@testable import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Auto chat placement in the Priority view (design/auto-chat-placement.md): a chat whose session
/// tag `placement` is `auto` says "Auto · <machine>" where its row names its place.
@Suite struct SidebarPriorityAutoPlaceTests {
    static func summary(_ tags: [String: Any]) -> [String: Any] {
        ["sessionId": "s1", "name": "s1", "lane": ["state": "idle"], "tags": tags]
    }

    @Test func theLaneReadsOnlyAKnownPlacementTag() {
        #expect(AgentActivityLane.of(summary: Self.summary(["placement": "auto"]))?.placement == "auto")
        #expect(AgentActivityLane.of(summary: Self.summary(["placement": "pinned"]))?.placement == "pinned")
        #expect(AgentActivityLane.of(summary: Self.summary(["placement": "elsewhere"]))?.placement == nil)
        #expect(AgentActivityLane.of(summary: Self.summary([:]))?.placement == nil)
    }

    @Test func anAutoPlacedRowSaysAutoBesideItsMachine() {
        let auto = AgentActivityLane(id: "a", name: "a", title: "a", peer: "build-box", parent: nil, state: .idle, since: Date(),
                                     error: nil, placement: "auto")
        let pinned = AgentActivityLane(id: "p", name: "p", title: "p", peer: "build-box", parent: nil, state: .idle, since: Date(),
                                       error: nil, placement: "pinned")
        let rows = AgentPriorityRanking().entries([auto, pinned], marks: .init(), now: Date())
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID["a"]?.autoPlaced == true)
        #expect(byID["a"]?.placeText == "Auto · build-box")
        #expect(byID["p"]?.autoPlaced == false)
        #expect(byID["p"]?.placeText == "build-box")
        #expect(SidebarPriorityEntry(id: "l", title: "l", state: .idle, autoPlaced: true).placeText == "Auto · This Mac")
        #expect(SidebarPriorityEntry(id: "l", title: "l", state: .idle).placeText == nil)
    }
}
