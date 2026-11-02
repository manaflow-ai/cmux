import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// A chat on another machine (Leo's DEV build, a Cloud chat: "Couldn't switch to claude-opus-5-5:
/// session/set_model is not available for a chat on another machine"): the page's model, mode and
/// option picks go to the owning daemon for this chat only (`agent-session-settings-v1`), and
/// acpmux's answer comes back as it is. An observer never picks.
@Suite(.timeLimit(.minutes(1))) struct RemoteAcpmuxSettingsTests {
    nonisolated final class FakeClient: AgentSessionRemoteClient {
        let calls = Mutex<[String]>([])
        let isReadOnly: Bool
        let served: Bool

        init(readOnly: Bool, served: Bool = true) {
            isReadOnly = readOnly
            self.served = served
        }

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            calls.withLock { $0.append("attach") }
            return Data(#"{"session":{"sessionId":"acp_1"},"events":[],"hasMore":false,"lastSeq":3}"#.utf8)
        }

        func events(_ page: AgentSessionPage) async throws -> Data { Data(#"{"events":[],"hasMore":false,"lastSeq":3}"#.utf8) }
        func prompt(id: String, text: String) async throws -> Data { Data(#"{}"#.utf8) }
        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                        personDecision: String?) async throws {}
        func detach() async {}
        func close() async {}

        func setModel(_ modelId: String) async throws -> Data {
            guard served else { throw AgentSessionRemoteError(code: "agent_session.settings_unsupported", message: "update") }
            calls.withLock { $0.append("model \(modelId)") }
            return Data("{}".utf8)
        }

        func setMode(_ modeId: String) async throws -> Data {
            calls.withLock { $0.append("mode \(modeId)") }
            return Data("{}".utf8)
        }

        func setConfig(id configId: String, value: String) async throws -> Data {
            calls.withLock { $0.append("config \(configId)=\(value)") }
            return Data(#"{"configOptions":[{"id":"effort","currentValue":"high"}]}"#.utf8)
        }
    }

    typealias Frames = RemoteAcpmuxObserverTests.Frames

    static func attached(_ client: FakeClient) async throws -> (RemoteAcpmuxWire, Frames) {
        let frames = Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "sub")
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/attach","params":{"sessionId":"sub"}}"#) { _ in }
        try await waitUntil { frames.reply(1) != nil }
        return (wire, frames)
    }

    static func code(_ frames: Frames, _ id: Int) -> String? {
        ((frames.reply(id)?["error"] as? [String: Any])?["data"] as? [String: Any])?["code"] as? String
    }

    @Test func modelModeAndOptionPicksGoToThisChat() async throws {
        let client = FakeClient(readOnly: false)
        let (wire, frames) = try await Self.attached(client)
        for frame in [
            #"{"jsonrpc":"2.0","id":2,"method":"session/set_model","params":{"sessionId":"sub","modelId":"claude-opus-5-5"}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"session/set_mode","params":{"sessionId":"acp_1","modeId":"acceptEdits"}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"session/set_config_option","params":{"sessionId":"sub","configId":"effort","value":"high"}}"#,
            // Another chat, or a pick with no value, changes nothing.
            #"{"jsonrpc":"2.0","id":5,"method":"session/set_model","params":{"sessionId":"acp_other","modelId":"opus"}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"session/set_mode","params":{"sessionId":"sub"}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"session/set_config_option","params":{"sessionId":"sub","configId":"effort","value":true}}"#,
        ] {
            wire.send(frame) { _ in }
        }
        try await Self.waitUntil { (2...7).allSatisfy { frames.reply($0) != nil } }
        #expect(frames.reply(2)?["result"] != nil)
        #expect(frames.reply(3)?["result"] != nil)
        // The page reads the agent's whole option list from the answer (direct.ts setConfig).
        let options = (frames.reply(4)?["result"] as? [String: Any])?["configOptions"] as? [[String: Any]]
        #expect(options?.first?["currentValue"] as? String == "high")
        for id in 5...7 { #expect(Self.code(frames, id) == RemoteAcpmuxWire.unsupported) }
        #expect(client.calls.withLock { $0 } == ["attach", "model claude-opus-5-5", "mode acceptEdits", "config effort=high"])
    }

    @Test func anOlderDaemonSaysToUpdateIt() async throws {
        let client = FakeClient(readOnly: false, served: false)
        let (wire, frames) = try await Self.attached(client)
        wire.send(#"{"jsonrpc":"2.0","id":2,"method":"session/set_model","params":{"sessionId":"sub","modelId":"opus"}}"#) { _ in }
        try await Self.waitUntil { frames.reply(2) != nil }
        #expect(Self.code(frames, 2) == "agent_session.settings_unsupported")
    }

    @Test func anObserverNeverPicks() async throws {
        let client = FakeClient(readOnly: true)
        let (wire, frames) = try await Self.attached(client)
        wire.send(#"{"jsonrpc":"2.0","id":2,"method":"session/set_model","params":{"sessionId":"sub","modelId":"opus"}}"#) { _ in }
        wire.send(#"{"jsonrpc":"2.0","id":3,"method":"session/set_mode","params":{"sessionId":"sub","modeId":"plan"}}"#) { _ in }
        try await Self.waitUntil { frames.reply(2) != nil && frames.reply(3) != nil }
        #expect(Self.code(frames, 2) == RemoteAcpmuxWire.readOnly)
        #expect(Self.code(frames, 3) == RemoteAcpmuxWire.readOnly)
        #expect(client.calls.withLock { $0 } == ["attach"])
    }

    private static func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
