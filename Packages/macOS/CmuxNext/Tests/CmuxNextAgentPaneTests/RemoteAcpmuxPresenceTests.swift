import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// Chat multiplayer (hq#4389) on a chat of another machine: the page's typing and view go to the
/// owning daemon for this chat only (`agent-session-presence-v1`), and who is in the chat comes
/// back as `_acpmux/presence`, for this chat only. An observer never types.
@Suite(.timeLimit(.minutes(1))) struct RemoteAcpmuxPresenceTests {
    nonisolated final class FakeClient: AgentSessionRemoteClient {
        let calls = Mutex<[String]>([])
        let handler = Mutex<(@Sendable (AgentSessionRemoteEvent) -> Void)?>(nil)
        let isReadOnly: Bool

        init(readOnly: Bool) { isReadOnly = readOnly }

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            calls.withLock { $0.append("attach") }
            self.handler.withLock { $0 = handler }
            return Data(#"{"session":{"sessionId":"acp_1"},"events":[],"hasMore":false,"lastSeq":3,"presence":{"sessionId":"acp_1","participants":[]}}"#.utf8)
        }

        func events(_ page: AgentSessionPage) async throws -> Data { Data(#"{"events":[],"hasMore":false,"lastSeq":3}"#.utf8) }
        func prompt(id: String, text: String) async throws -> Data { Data(#"{}"#.utf8) }
        func cancel() async throws {}
        func permission(id: String, option: String, decisionNonce: String?, personDecision: String?) async throws {}
        func detach() async {}
        func close() async {}
        func typing(_ on: Bool) async throws { calls.withLock { $0.append("typing \(on)") } }
        func view(_ visible: Bool) async throws { calls.withLock { $0.append("view \(visible)") } }

        func push(_ event: AgentSessionRemoteEvent) { handler.withLock { $0 }?(event) }
    }

    typealias Frames = RemoteAcpmuxObserverTests.Frames

    static func attached(readOnly: Bool) async throws -> (RemoteAcpmuxWire, FakeClient, Frames) {
        let client = FakeClient(readOnly: readOnly)
        let frames = Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "sub")
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/attach","params":{"sessionId":"sub"}}"#) { _ in }
        try await waitUntil { frames.reply(1) != nil }
        return (wire, client, frames)
    }

    static func code(_ frames: Frames, _ id: Int) -> String? {
        ((frames.reply(id)?["error"] as? [String: Any])?["data"] as? [String: Any])?["code"] as? String
    }

    @Test func typingAndViewGoToThisChatAndPresenceComesBack() async throws {
        let (wire, client, frames) = try await Self.attached(readOnly: false)
        // The attach page's own presence reaches the page as acpmux answered it.
        let page = try #require(frames.reply(1)?["result"] as? [String: Any])
        #expect((page["presence"] as? [String: Any])?["sessionId"] as? String == "acp_1")
        for frame in [
            #"{"jsonrpc":"2.0","id":2,"method":"_acpmux/typing","params":{"sessionId":"sub","on":true}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"_acpmux/view","params":{"sessionId":"acp_1","visible":false}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"_acpmux/typing","params":{"sessionId":"acp_other","on":true}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"_acpmux/typing","params":{"sessionId":"sub"}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"_acpmux/view","params":{"sessionId":"acp_other","visible":true}}"#,
        ] {
            wire.send(frame) { _ in }
        }
        try await Self.waitUntil { (2...6).allSatisfy { frames.reply($0) != nil } }
        #expect(frames.reply(2)?["result"] != nil)
        #expect(frames.reply(3)?["result"] != nil)
        for id in 4...6 { #expect(Self.code(frames, id) == RemoteAcpmuxWire.unsupported) }
        #expect(client.calls.withLock { $0 } == ["attach", "typing true", "view false"])

        client.push(.presence(Data(#"{"sessionId":"acp_other","participants":[]}"#.utf8)))
        client.push(.presence(Data(#"{"sessionId":"acp_1","participants":[{"id":"owner","name":"Owner","devices":2,"viewing":true,"typing":true}]}"#.utf8)))
        try await Self.waitUntil { !frames.notifications("_acpmux/presence").isEmpty }
        let pushed = frames.notifications("_acpmux/presence")
        #expect(pushed.count == 1)
        let params = try #require(pushed.first?["params"] as? [String: Any])
        #expect(params["sessionId"] as? String == "acp_1")
        #expect((params["participants"] as? [[String: Any]])?.first?["typing"] as? Bool == true)
    }

    @Test func anObserverNeverTypesButStillSaysWhetherItShowsTheChat() async throws {
        let (wire, client, frames) = try await Self.attached(readOnly: true)
        wire.send(#"{"jsonrpc":"2.0","id":2,"method":"_acpmux/typing","params":{"sessionId":"sub","on":true}}"#) { _ in }
        wire.send(#"{"jsonrpc":"2.0","id":3,"method":"_acpmux/view","params":{"sessionId":"sub","visible":true}}"#) { _ in }
        try await Self.waitUntil { frames.reply(2) != nil && frames.reply(3) != nil }
        #expect(Self.code(frames, 2) == RemoteAcpmuxWire.readOnly)
        #expect(frames.reply(3)?["result"] != nil)
        #expect(client.calls.withLock { $0 } == ["attach", "view true"])
    }

    private static func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
