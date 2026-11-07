import CmuxHomeCore
@testable import CmuxNextHome
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The Messages page's agent pills: each turn's agents row after the message it follows, with the
/// agents' chats, and the shown Chief chat held open in the store only while the page listens.
@MainActor
struct HomePageAgentsTests {
    private func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { return Issue.record("the condition never held") }
            await Task.yield()
        }
    }

    private func message(_ id: String) -> TranscriptItem {
        TranscriptItem(key: IdempotencyKey("k-\(id)"), seq: 1, author: ParticipantID("me"), parts: [.text(id)],
                       createdAt: Date(timeIntervalSince1970: 10), delivery: .committed, messageID: MessageID(id))
    }

    private func fold(_ group: String, peers: [String], states: [HomeAgentMessageRow.PeerState]) -> TranscriptItem {
        var item = TranscriptItem(key: IdempotencyKey("fold-\(group)"), seq: nil, author: ParticipantID("chief"), parts: [],
                                  createdAt: Date(timeIntervalSince1970: 11), delivery: .committed)
        var row = HomeAgentMessageRow(group: group, kind: .fold(count: peers.count, peers: peers, expanded: false))
        row.peerStates = states
        row.peerTitles = peers.map { "Task \($0)" }
        row.peerUnread = states.map { $0 == .reported }
        item.agentMessage = row
        return item
    }

    @Test func eachAgentsRowFollowsItsMessageAndEachAgentsChatGoesOnce() {
        let items = [fold("g0", peers: ["a0"], states: [.queued]), message("m1"),
                     fold("g1", peers: ["a1", "a2"], states: [.told, .reported]),
                     message("m2"), fold("g2", peers: ["a2"], states: [.stopped])]
        let started = Date(timeIntervalSince1970: 100)
        let payload = HomePageAgents.payload(ConversationID("c1"), items: items) { peer in
            peer == "a0" ? nil : HomeAgentThread(peer: peer, title: "Task \(peer)", state: .reported, task: "do it",
                                                 entries: [.init(id: "e1", outgoing: false, text: "done", date: started)],
                                                 startedAt: started, endedAt: started.addingTimeInterval(5), newestReportAt: started,
                                                 workspaceLink: URL(string: "cmux://chief/h/session/s-\(peer)"))
        }
        let rows = payload["rows"]?.arrayValue ?? []
        #expect(rows.map { $0["after"] } == [.null, "m1", "m2"])
        #expect(rows[1]["peers"] == .array(["a1", "a2"]))
        #expect(rows[1]["titles"] == .array(["Task a1", "Task a2"]))
        #expect(rows[1]["states"] == .array(["told", "reported"]))
        #expect(rows[1]["unread"] == .array([.bool(false), .bool(true)]))
        let threads = payload["threads"]?.arrayValue ?? []
        #expect(threads.map { $0["peer"] } == ["a1", "a2"])
        #expect(threads[0] == .object([
            "peer": "a1", "title": "Task a1", "state": "reported", "task": "do it",
            "entries": .array([.object(["id": "e1", "sender": "agent", "text": "done"])]),
            "startedAt": .number(100_000), "endedAt": .number(105_000), "workspaceLink": "cmux://chief/h/session/s-a1",
        ]))
        #expect(payload["conversation"] == "c1")
    }

    @Test func theShownChiefChatIsHeldOnlyWhileThePageListens() async throws {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        defer { store.stop() }
        await until { store.isOnline && !store.rows.isEmpty }
        let chief = try #require(store.rows.first { $0.kind == .chief }?.id)
        let other = try #require(store.rows.first { $0.kind != .chief }?.id)
        let agents = HomePageAgents { store }
        agents.show(chief)
        #expect(agents.held == nil) // nobody listens yet
        var events: [JSONValue] = []
        let subscription = agents.subscribe { events.append($0) }
        #expect(agents.held == chief)
        #expect(events.last?["conversation"]?.stringValue == chief.rawValue)
        agents.show(other)
        #expect(agents.held == nil) // a chat that is not a Chief's has no agents
        agents.show(chief)
        #expect(agents.held == chief)
        subscription.cancel()
        #expect(agents.held == nil)
    }

    @Test func aCallForAnotherChatOrWithoutAPeerIsRefusedAndANoteIsThePersonsOnly() async throws {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        defer { store.stop() }
        await until { store.isOnline && !store.rows.isEmpty }
        let chief = try #require(store.rows.first { $0.kind == .chief }?.id)
        let agents = HomePageAgents { store }
        let subscription = agents.subscribe { _ in }
        defer { subscription.cancel() }
        agents.show(chief)
        await #expect(throws: PageError.self) {
            try await agents.call("agents.seen", .object(["conversation": "other", "peer": "a1"]), userGesture: true, personOnly: "no")
        }
        await #expect(throws: PageError.self) {
            try await agents.call("agents.seen", .object(["conversation": .string(chief.rawValue)]), userGesture: true, personOnly: "no")
        }
        await #expect(throws: PageError.self) {
            try await agents.call("agents.note", .object(["conversation": .string(chief.rawValue), "peer": "a1", "text": "hi"]),
                                  userGesture: false, personOnly: "no")
        }
        #expect(try await agents.call("agents.seen", .object(["conversation": .string(chief.rawValue), "peer": "a1"]),
                                      userGesture: true, personOnly: "no") == .null)
    }
}
