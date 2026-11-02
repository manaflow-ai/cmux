import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// A Cloud chat's own sign-in on its machine (Leo 2026-11-01, on the one-click sign-in: "yes those
/// are important"): the card's `_acpmux/agent_login/*` frames go to the owning daemon for this chat
/// only (`agent-session-login-v1`), acpmux's refusal comes back with its reason, the handshake names
/// the `agent_login` feature only where the daemon relays it, and an observer never signs in.
@Suite(.timeLimit(.minutes(1))) struct RemoteAcpmuxLoginTests {
    nonisolated final class FakeClient: AgentSessionRemoteClient {
        let calls = Mutex<[String]>([])
        let isReadOnly: Bool
        let served: Bool

        init(readOnly: Bool = false, served: Bool = true) {
            isReadOnly = readOnly
            self.served = served
        }

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            Data(#"{"session":{"sessionId":"acp_1"},"events":[],"hasMore":false,"lastSeq":3}"#.utf8)
        }

        func events(_ page: AgentSessionPage) async throws -> Data { Data(#"{"events":[],"hasMore":false,"lastSeq":3}"#.utf8) }
        func prompt(id: String, text: String) async throws -> Data { Data(#"{}"#.utf8) }
        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                        personDecision: String?) async throws {}
        func detach() async {}
        func close() async {}
        func setModel(_ modelId: String) async throws -> Data { Data("{}".utf8) }
        func setMode(_ modeId: String) async throws -> Data { Data("{}".utf8) }
        func setConfig(id configId: String, value: String) async throws -> Data { Data("{}".utf8) }

        func servesLogin() async -> Bool { served }

        func login(_ op: String, _ fields: [String: String]) async throws -> Data {
            calls.withLock { $0.append(([op] + fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }).joined(separator: " ")) }
            if fields["code"] == "wrong" { return Data(#"{"refused":{"reason":"bad_code"}}"#.utf8) }
            switch op {
            case "start": return Data(#"{"loginId":"login_1","url":"https://claude.ai/oauth/authorize","needsCode":true}"#.utf8)
            case "finish": return Data(#"{"signedIn":true,"restarted":true}"#.utf8)
            case "api_key": return Data(#"{"saved":true,"restarted":true}"#.utf8)
            default: return Data("{}".utf8)
            }
        }
    }

    typealias Frames = RemoteAcpmuxObserverTests.Frames

    static func wire(_ client: FakeClient) async throws -> (RemoteAcpmuxWire, Frames) {
        let frames = Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "sub")
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        return (wire, frames)
    }

    static func error(_ frames: Frames, _ id: Int) -> [String: Any]? {
        (frames.reply(id)?["error"] as? [String: Any])?["data"] as? [String: Any]
    }

    @Test func theHandshakeNamesTheFeatureOnlyWhereTheDaemonRelaysIt() async throws {
        for served in [true, false] {
            let (wire, frames) = try await Self.wire(FakeClient(served: served))
            wire.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#) { _ in }
            try await Self.waitUntil { frames.reply(1) != nil }
            let acpmux = ((frames.reply(1)?["result"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
            #expect(((acpmux?["features"] as? [String])?.contains("agent_login") ?? false) == served)
            #expect(acpmux?["capabilities"] == nil)
        }
    }

    /// #30894: a new chat has no session (nor client) before its first send, yet its first failed
    /// turn must offer Sign in: its `initialize` names the feature from its machine's daemon read,
    /// with and without a Cloud owner answer.
    @Test func aNewChatNamesTheFeatureBeforeItsFirstSend() async throws {
        let start: RemoteAcpmuxWire.Start = { _, _, _ in throw CancellationError() }
        for served in [true, false] {
            for owner in [nil, { true } as RemoteAcpmuxWire.OwnerCloud] {
                let frames = Frames()
                let wire = RemoteAcpmuxWire(start: start, ownerCloud: owner, servesLogin: served)
                try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
                wire.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#) { _ in }
                try await Self.waitUntil { frames.reply(1) != nil }
                let acpmux = ((frames.reply(1)?["result"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
                #expect(((acpmux?["features"] as? [String])?.contains("agent_login") ?? false) == served)
            }
        }
    }

    @Test func eachStepGoesToThisChatsDaemon() async throws {
        let client = FakeClient()
        let (wire, frames) = try await Self.wire(client)
        for frame in [
            #"{"jsonrpc":"2.0","id":2,"method":"_acpmux/agent_login/start","params":{"agent":"claude","sessionId":"sub"}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"_acpmux/agent_login/finish","params":{"loginId":"login_1","code":"wrong","sessionId":"sub"}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"_acpmux/agent_login/finish","params":{"loginId":"login_1","code":"abc","sessionId":"sub"}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"_acpmux/agent_login/api_key","params":{"agent":"codex","key":"sk-x","sessionId":"sub"}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"_acpmux/agent_login/cancel","params":{"loginId":"login_1","sessionId":"sub"}}"#,
            // Another chat, or a step with a missing field, goes nowhere.
            #"{"jsonrpc":"2.0","id":7,"method":"_acpmux/agent_login/finish","params":{"loginId":"login_1","sessionId":"acp_other"}}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"_acpmux/agent_login/api_key","params":{"agent":"claude","sessionId":"sub"}}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"_acpmux/agent_login/start","params":{"sessionId":"sub"}}"#,
            #"{"jsonrpc":"2.0","id":10,"method":"_acpmux/agent_login/start","params":{"agent":"claude"}}"#,
        ] {
            wire.send(frame) { _ in }
        }
        try await Self.waitUntil { (2...10).allSatisfy { frames.reply($0) != nil } }
        #expect((frames.reply(2)?["result"] as? [String: Any])?["loginId"] as? String == "login_1")
        #expect(Self.error(frames, 3)?["reason"] as? String == "bad_code")
        #expect(Self.error(frames, 3)?["code"] as? String == RemoteAcpmuxWire.loginRefused)
        #expect((frames.reply(4)?["result"] as? [String: Any])?["signedIn"] as? Bool == true)
        #expect((frames.reply(5)?["result"] as? [String: Any])?["saved"] as? Bool == true)
        #expect(frames.reply(6)?["result"] != nil)
        for id in 7...10 { #expect(Self.error(frames, id)?["code"] as? String == RemoteAcpmuxWire.unsupported) }
        #expect(client.calls.withLock { $0 }.sorted() == [
            "api_key agent=codex key=sk-x",
            "cancel login_id=login_1",
            "finish code=abc login_id=login_1",
            "finish code=wrong login_id=login_1",
            "start agent=claude",
        ])
    }

    @Test func anObserverNeverSignsIn() async throws {
        let client = FakeClient(readOnly: true)
        let (wire, frames) = try await Self.wire(client)
        wire.send(#"{"jsonrpc":"2.0","id":2,"method":"_acpmux/agent_login/start","params":{"agent":"claude","sessionId":"sub"}}"#) { _ in }
        try await Self.waitUntil { frames.reply(2) != nil }
        #expect(Self.error(frames, 2)?["code"] as? String == RemoteAcpmuxWire.readOnly)
        #expect(client.calls.withLock { $0 }.isEmpty)
    }

    private static func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
