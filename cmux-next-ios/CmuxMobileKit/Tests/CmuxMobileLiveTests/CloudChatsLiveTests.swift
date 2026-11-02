#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileNotifications
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Exercises the production ACP client/source over the Cloud service, including
/// two VMs that use the same local session id. No transcript-specific mock source.
@MainActor @Suite struct CloudChatsLiveTests {
    final class Wire: MacLink, @unchecked Sendable {
        let transport = TransportKind.wireGuard
        let states: AsyncStream<LinkState> = AsyncStream { $0.finish() }
        private let lock = NSLock()
        private var opened: [(String, [String: String])] = []
        private var prompts: [(String, String, String)] = []
        var services: [(String, [String: String])] { lock.withLock { opened } }
        var sent: [(String, String, String)] { lock.withLock { prompts } }

        func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
            lock.withLock { opened.append((service, args)) }
            let machine = args["machine_id"] ?? "wrong-local-mac"
            let mock = MockMacLink { [self] _, data in
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let method = object["method"] as? String else { return [] }
                let params = object["params"] as? [String: Any] ?? [:]
                let id = object["id"] ?? NSNull()
                let result: [String: Any]
                var notices: [Data] = []
                switch method {
                case "initialize": result = ["protocolVersion": 1]
                case "_acpmux/watch": result = ["sessions": [
                    ["sessionId": "shared", "name": machine, "harness": "fake", "cwd": "/w", "status": "idle"],
                    ["sessionId": "peer/shared", "peer": "other", "harness": "fake", "status": "idle"],
                ]]
                case "_acpmux/attach": result = [
                    "session": ["sessionId": "shared", "status": "idle", "pending": []],
                    "hasMore": false, "lastSeq": 3,
                    "events": [
                        ["sessionId": "shared", "seq": 1, "at": 1, "dir": "mux", "kind": "user_message",
                         "msg": ["text": "Read this Cloud machine", "promptId": "p", "turnId": "t"]],
                        ["sessionId": "shared", "seq": 2, "at": 2, "dir": "in", "kind": "agent_message_chunk",
                         "msg": ["method": "session/update", "params": ["update": [
                            "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": machine],
                         ]]]],
                        ["sessionId": "shared", "seq": 3, "at": 3, "dir": "mux", "kind": "turn_result",
                         "msg": ["turnId": "t", "status": "completed"]],
                    ],
                ]
                case "session/prompt":
                    let text = (params["prompt"] as? [[String: Any]])?.first?["text"] as? String ?? ""
                    let session = params["sessionId"] as? String ?? ""
                    lock.withLock { prompts.append((machine, session, text)) }
                    result = [:]
                    let record: [String: Any] = [
                        "jsonrpc": "2.0", "method": "_acpmux/event", "params": [
                            "sessionId": session, "seq": 4, "at": 4, "dir": "mux", "kind": "user_message",
                            "msg": ["text": text, "promptId": "next", "turnId": "next"],
                        ],
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: record) { notices.append(data) }
                default: result = [:]
                }
                return [(try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])) ?? Data()] + notices
            }
            return try await mock.openChannel(service: service, args: args)
        }

        func ping() async throws -> UInt32 { 1 }
        func close() async {}
    }

    func machine(_ id: String, team: String = "team") throws -> CloudChatMachine {
        try JSONDecoder().decode(CloudChatMachine.self, from: JSONSerialization.data(withJSONObject: [
            "machine_id": id, "team_id": team, "name": id,
        ]))
    }

    @Test func directoryScopeRejectsOtherCloudTeamsAndSortsByStableID() throws {
        let listed = [
            try machine("vm-b", team: "cloud-team-b"),
            try machine("vm-a", team: "cloud-team-a"),
            try machine("vm-z", team: "cloud-team-a"),
        ]
        let attention = try #require(CloudChatAttention(userInfo: ["cmux": ["cloud": [
            "kind": "question", "event_id": "e", "machine_id": "vm-z", "session_id": "s", "team_id": "cloud-team-a",
        ]]]))
        let scoped = CloudChatDirectory.scopedMachines(listed, attention: attention)
        #expect(scoped.map(\.id) == ["cloud-team-a\u{1}vm-z"])
        #expect(CloudChatDirectory.scopedMachines(listed, attention: nil).map(\.id) == [
            "cloud-team-a\u{1}vm-a", "cloud-team-a\u{1}vm-z", "cloud-team-b\u{1}vm-b",
        ])
    }

    @Test func attentionFindsAnotherPairedMacWithAnExactCloudTeamAndMachine() async throws {
        let attention = try #require(CloudChatAttention(userInfo: ["cmux": ["cloud": [
            "kind": "permission", "event_id": "e", "machine_id": "vm", "session_id": "shared",
            "team_id": "cloud-team",
        ]]]))
        let wrongTeam = try machine("vm", team: "different-team")
        let unrelated = try machine("other", team: "cloud-team")
        let owner = try machine("vm", team: "cloud-team")
        let directories = ["focused": [wrongTeam, unrelated], "other": [owner]]
        let match = await CloudChatAttentionResolver.find(macIDs: ["focused", "other"], attention: attention) {
            directories[$0] ?? []
        }
        #expect(match?.macID == "other")
        #expect(match?.machine.id == owner.id)
        #expect(match?.id == "other\u{1}" + owner.id)
    }

    @Test func attentionNeverFallsBackToAnotherTeamOrUnavailableMac() async throws {
        enum Offline: Error { case disconnected }
        let attention = try #require(CloudChatAttention(userInfo: ["cmux": ["cloud": [
            "kind": "question", "event_id": "e", "machine_id": "vm", "session_id": "shared",
            "team_id": "owner-team",
        ]]]))
        let wrong = try machine("vm", team: "other-team")
        let match = await CloudChatAttentionResolver.find(macIDs: ["focused", "offline"], attention: attention) { id in
            if id == "offline" { throw Offline.disconnected }
            return [wrong]
        }
        #expect(match == nil)
    }

    @Test func attentionWithNoPairedMacsStaysUnavailable() async throws {
        let attention = try #require(CloudChatAttention(userInfo: ["cmux": ["cloud": [
            "kind": "done", "event_id": "e", "machine_id": "vm", "session_id": "s", "team_id": "owner-team",
        ]]]))
        let match = await CloudChatAttentionResolver.find(macIDs: [], attention: attention) { _ in
            Issue.record("No directory should be opened")
            return []
        }
        #expect(match == nil)
    }

    @Test func historyAndSendStayOnTheSelectedCloudMachine() async throws {
        let wire = Wire()
        let first = CloudChatRelay(machine: try machine("vm-a"), macID: "mac")
        let second = CloudChatRelay(machine: try machine("vm-b"), macID: "mac")
        first.bind(wire)
        second.bind(wire)
        #expect(await ObservationWait({ first.hub.isReady && second.hub.isReady }, budget: .seconds(2)).value)
        #expect(wire.services.allSatisfy { $0.0 == "cloud-acpmux" && $0.1["team_id"] == "team" })
        let a = try #require(first.store(sessionID: "shared"))
        let b = try #require(second.store(sessionID: "shared"))
        #expect(a !== b)
        #expect(first.store(sessionID: "missing") == nil)
        #expect(first.store(sessionID: "peer/shared") == nil)
        #expect(await ObservationWait({ a.turns.first?.answerMarkdown == "vm-a" && b.turns.first?.answerMarkdown == "vm-b" },
                                     budget: .seconds(2)).value)
        a.send(prompt: "continue-a")
        // Wait for the user_message the remote journal returned, then verify
        // which machine actually received the prompt.
        #expect(await ObservationWait({ a.turns.count > 1 }, budget: .seconds(2)).value)
        #expect(wire.sent.contains { $0.0 == "vm-a" && $0.1 == "shared" && $0.2 == "continue-a" })
        #expect(!wire.sent.contains { $0.0 == "vm-b" })
        first.disconnect()
        second.disconnect()
    }

    @Test func reconnectKeepsTheChatStoreAndUsesTheNewCarrier() async throws {
        let relay = CloudChatRelay(machine: try machine("vm"), macID: "mac")
        let old = Wire()
        relay.bind(old)
        #expect(await ObservationWait({ relay.hub.isReady }, budget: .seconds(2)).value)
        let store = try #require(relay.store(sessionID: "shared"))
        relay.disconnect()
        #expect(await ObservationWait({ !relay.hub.isReady }, budget: .seconds(2)).value)
        let new = Wire()
        relay.bind(new)
        #expect(await ObservationWait({ relay.hub.isReady }, budget: .seconds(2)).value)
        #expect(relay.store(sessionID: "shared") === store)
        #expect(new.services.first?.0 == "cloud-acpmux")
        #expect(new.services.first?.1["machine_id"] == "vm")
        relay.disconnect()
    }

    @Test func accountTeardownRetiresARelayEvenWhenAScreenRetainsIt() async throws {
        let relay = CloudChatRelay(machine: try machine("vm"), macID: "mac")
        let wire = Wire()
        relay.bind(wire)
        #expect(await ObservationWait({ relay.hub.isReady }, budget: .seconds(2)).value)
        _ = try #require(relay.store(sessionID: "shared"))
        relay.retire()
        #expect(relay.isRetired)
        #expect(relay.hub.sessions.isEmpty)
        #expect(relay.store(sessionID: "shared") == nil)
        let opened = wire.services.count
        relay.bind(wire)
        #expect(wire.services.count == opened)
    }
}

private actor DirectoryChannel: LinkChannel {
    nonisolated let id: UInt32 = 1
    private var chunks: [Data]
    init(_ chunks: [Data]) { self.chunks = chunks }
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data? { chunks.isEmpty ? nil : chunks.removeFirst() }
    func close(code: String, reason: String) async { chunks = [] }
}

@Suite struct CloudChatDirectoryTests {
    @Test func readsAFragmentedDirectoryAndKeepsTeamIdentity() async throws {
        let channel = DirectoryChannel([
            Data(#"{"machines":[{"machine_id":"vm","team_id":"one","na"#.utf8),
            Data(#"me":"Cloud"},{"machine_id":"vm","team_id":"two","name":"Cloud"}]}"#.utf8),
        ])
        let machines = try await CloudChatDirectory.read(channel)
        #expect(machines.count == 2)
        #expect(machines[0].id != machines[1].id)
    }

    @Test func aTruncatedDirectoryNeverReturnsAPartialList() async {
        await #expect(throws: (any Error).self) {
            _ = try await CloudChatDirectory.read(DirectoryChannel([Data(#"{"machines":["#.utf8)]))
        }
    }
}
#endif
