import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextDaemon
import Observation
import Testing

/// Chat history needs the set of chats represented by open tabs, but a turn-state update does not
/// change that set. Keep the 400-tab observation scope on the per-session chat projection.
@MainActor @Suite(.serialized)
struct SidebarChatHistoryObservationTests {
    private static let host = "install:chat-history-harness"

    private func fixture(count: Int = 400) -> ([TabModel], AgentLaneStore) {
        let lanes = AgentLaneStore()
        var all: [String: AgentActivityLane] = [:]
        var tabs: [TabModel] = []
        for index in 0..<count {
            let session = "chat-history-(index)"
            all[session] = AgentActivityLane(id: session, name: session, title: "Chat (index)", peer: nil,
                                             parent: nil, state: .idle, since: nil, error: nil,
                                             harness: "claude", chat: "claude-code:(session)")
            var snapshot = TabSnapshot(surface: SurfaceID(rawValue: UInt64(index + 1)),
                                       tabResourceID: ResourceID(rawValue: "tab_chat_history_(index)"),
                                       kind: .conversation, title: "Chat (index)")
            snapshot.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: Self.host,
                                                                                       session: session,
                                                                                       harness: "claude"))
            tabs.append(TabModel(snapshot))
        }
        lanes.lanes = all
        return (tabs, lanes)
    }

    private func invalidations(_ read: () -> Void, mutate: () -> Void) -> Int {
        var count = 0
        withObservationTracking(read) { count += 1 }
        mutate()
        return count
    }

    @Test func turnStateDoesNotInvalidateTheFourHundredTabChatProjection() {
        let (tabs, lanes) = fixture()
        defer { lanes.lanes = [:] }

        let before = invalidations({
            _ = SidebarChatHistoryFeed.liveChats(tabs, lanes: lanes.lanes, localHost: Self.host)
        }) {
            lanes.set("chat-history-0", AgentActivityLane(id: "chat-history-0", name: "chat-history-0",
                                                            title: "Chat 0", peer: nil, parent: nil,
                                                            state: .working, since: nil, error: nil,
                                                            harness: "claude", chat: "claude-code:chat-history-0"))
        }

        let after = invalidations({
            _ = SidebarChatHistoryFeed.liveChats(tabs, lanes: lanes, localHost: Self.host)
        }) {
            lanes.set("chat-history-1", AgentActivityLane(id: "chat-history-1", name: "chat-history-1",
                                                            title: "Chat 1", peer: nil, parent: nil,
                                                            state: .working, since: nil, error: nil,
                                                            harness: "claude", chat: "claude-code:chat-history-1"))
        }

        #expect(before == 1)
        #expect(after == 0)
    }

    @Test func chatBindingStillInvalidatesTheProjection() {
        let (tabs, lanes) = fixture(count: 2)
        defer { lanes.lanes = [:] }

        let invalidation = invalidations({
            _ = SidebarChatHistoryFeed.liveChats(tabs, lanes: lanes, localHost: Self.host)
        }) {
            lanes.set("chat-history-0", AgentActivityLane(id: "chat-history-0", name: "chat-history-0",
                                                            title: "Chat 0", peer: nil, parent: nil,
                                                            state: .idle, since: nil, error: nil,
                                                            harness: "claude", chat: "claude-code:renamed"))
        }

        #expect(invalidation == 1)
    }
}
