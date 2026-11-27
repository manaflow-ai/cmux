import CmuxNextAgentActivity
import Foundation
import Testing

/// `AgentLaneStore.set` keeps `names` and `sessionStarts` by the session it writes, never by a pass over every lane
/// (hq#22614, hq#11707: 2-8 s main-thread hangs in the whole-store rebuild, `syncNames`, on each turn-state message
/// that brought or renamed a session, with Leo's 214 chats and his peers' lanes).
@MainActor
@Suite struct AgentLaneStoreNamesCostTests {
    private static func lane(_ id: String, name: String, start: Date?) -> AgentActivityLane {
        AgentActivityLane(id: id, name: name, title: id, peer: nil, parent: nil, state: .working, since: nil, error: nil, createdAt: start)
    }

    /// What the old whole-store rebuild made of `lanes`: the reference for both values.
    private static func reference(_ lanes: [String: AgentActivityLane]) -> (Set<String>, [String: Date]) {
        (Set(lanes.values.map(\.name)),
         Dictionary(lanes.values.compactMap { lane in lane.createdAt.map { (lane.name, $0) } }, uniquingKeysWith: max))
    }

    /// Sessions come, go, share a name, are renamed and learn their start: after each write the names and starts are
    /// what a whole rebuild makes of the store.
    @Test func namesAndStartsFollowEachWriteAsAWholeRebuildWould() {
        let store = AgentLaneStore()
        var rng = SystemRandomNumberGenerator()
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        for step in 0..<2_000 {
            let session = "s\(Int.random(in: 0..<40, using: &rng))"
            let lane: AgentActivityLane? = Int.random(in: 0..<5, using: &rng) == 0 ? nil
                : Self.lane(session, name: "n\(Int.random(in: 0..<12, using: &rng))",
                            start: Bool.random(using: &rng) ? epoch.addingTimeInterval(Double(Int.random(in: 0..<50, using: &rng))) : nil)
            store.set(session, lane)
            let (names, starts) = Self.reference(store.lanes)
            #expect(store.names == names, "step \(step)")
            #expect(store.sessionStarts == starts, "step \(step)")
        }
        // A whole-store write rebuilds the index; writes after it keep following.
        store.lanes = ["a": Self.lane("a", name: "x", start: epoch), "b": Self.lane("b", name: "x", start: nil)]
        store.set("a", nil)
        #expect(store.names == ["x"])
        #expect(store.sessionStarts.isEmpty)
        store.set("b", nil)
        #expect(store.names.isEmpty)
    }

    /// 300 chats (and 3,000 peers' lanes beside them), then 20 messages per chat that each rename it: the main-thread
    /// cost of one message stays flat whatever else the store holds. Before (the old rebuild, timed here on the same
    /// store) each such message cost a pass over all 3,300 lanes.
    @Test func aRenameCostsItsSessionNotEveryLane() {
        let store = AgentLaneStore()
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        var lanes: [String: AgentActivityLane] = [:]
        for index in 0..<3_000 { lanes["peer\(index)"] = Self.lane("peer\(index)", name: "peer\(index)", start: epoch) }
        for index in 0..<300 { lanes["chat\(index)"] = Self.lane("chat\(index)", name: "chat\(index)", start: epoch) }
        store.lanes = lanes
        let messages = 20
        let clock = ContinuousClock()
        var oldRebuild = Duration.zero
        let elapsed = clock.measure {
            for round in 0..<messages {
                for index in 0..<300 {
                    store.set("chat\(index)", Self.lane("chat\(index)", name: "chat\(index)-r\(round)",
                                                       start: epoch.addingTimeInterval(Double(round))))
                }
            }
        }
        // The old cost, on the same store: one whole rebuild per message (measured for 1 in 10 messages, scaled).
        for _ in 0..<(messages * 300 / 10) {
            oldRebuild += clock.measure { _ = Self.reference(store.lanes) }
        }
        let count = Double(messages * 300)
        let perMessage = elapsed / count
        let oldPerMessage = oldRebuild / (count / 10)
        print("AgentLaneStore.set rename with 3,300 lanes: \(perMessage) per message now; old rebuild alone: \(oldPerMessage)")
        let (names, _) = Self.reference(store.lanes)
        #expect(store.names == names)
        // Generous for a loaded CI runner: the old rebuild alone was about 0.5 ms a message here.
        #expect(perMessage < .microseconds(200), "one message cost \(perMessage)")
    }
}
