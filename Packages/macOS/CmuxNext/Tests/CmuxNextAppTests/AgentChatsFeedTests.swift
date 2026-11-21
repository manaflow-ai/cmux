import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextApps
import Foundation
import Testing

/// NIGHTLY 23c9f5a, 2026-11-11 01:11:27Z: a 2.0 s main-thread hang in `AgentLaneStore.agentChats`, which the
/// `agent_chat.changed` feed ran under its observation on every lane change: it mapped and compared every lane each
/// agent step. The feed now observes the store's revision, which a write bumps only when a lane changed.
@MainActor @Suite(.serialized) struct AgentChatsFeedTests {
    static func lane(_ id: String, step: String? = nil) -> AgentActivityLane {
        AgentActivityLane(id: id, name: id, title: id, peer: nil, parent: nil, state: .working, since: nil, error: nil, step: step)
    }

    @Test func aWriteBumpsTheRevisionOnlyWhenALaneChanged() {
        let store = AgentLaneStore()
        let start = store.revision
        store.set("a", Self.lane("a", step: "reading"))
        #expect(store.revision == start + 1)
        store.set("a", Self.lane("a", step: "reading"))
        #expect(store.revision == start + 1, "the same lane again changes nothing")
        store.set("a", Self.lane("a", step: "writing"))
        #expect(store.revision == start + 2)
        store.lanes = store.lanes
        #expect(store.revision == start + 2, "the same map again changes nothing")
        store.set("a", nil)
        #expect(store.revision == start + 3)
    }

    @Test func theFeedHearsALaneChangeWithoutReadingTheLanes() async {
        let store = AgentLaneStore()
        for index in 0..<2_000 { store.set("s\(index)", Self.lane("s\(index)")) }
        let feed = AppProviderChangeFeed.agentChats(store)
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        var heard = stream.makeAsyncIterator()
        feed.attach { family in continuation.yield(family) }
        #expect(await heard.next() == "agent_chat", "a new carrier hears once")
        store.set("s7", Self.lane("s7", step: "next step"))
        #expect(await heard.next() == "agent_chat", "a lane's change is sent")
        feed.attach(nil)
    }
}
