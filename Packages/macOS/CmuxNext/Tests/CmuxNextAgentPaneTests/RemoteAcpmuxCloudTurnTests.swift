import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite(.timeLimit(.minutes(1))) struct RemoteAcpmuxCloudTurnTests {
    nonisolated final class Client: AgentSessionRemoteClient {
        let calls = Mutex<[String]>([])
        let isReadOnly = false
        let replay: Bool
        let submissionFails: Bool
        init(replay: Bool = false, submissionFails: Bool = false) { self.replay = replay; self.submissionFails = submissionFails }
        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data { Data("{}".utf8) }
        func events(_ page: AgentSessionPage) async throws -> Data { Data("{}".utf8) }
        func prompt(id: String, text: String) async throws -> Data {
            calls.withLock { $0.append("unfenced") }
            return Data("{}".utf8)
        }
        func prepareCloudTurn(id: String, scope: Data) async throws -> Data {
            #expect(String(decoding: scope, as: UTF8.self) == "verified-state")
            calls.withLock { $0.append("prepare") }
            if replay { return Data(#"{"accepted":{"prompt_id":"prompt_1","turn_id":"turn_1","queued":false}}"#.utf8) }
            return Data(#"{"session":"session_1","turn":"turn_1"}"#.utf8)
        }
        func abandonCloudTurn(id: String) async throws { calls.withLock { $0.append("abandon") } }
        func prompt(id: String, text: String, cloudTurn: Data) async throws -> Data {
            #expect(String(decoding: cloudTurn, as: UTF8.self) == "scoped-capability")
            calls.withLock { $0.append("fenced") }
            if submissionFails { throw CancellationError() }
            return Data(#"{"turn_id":"turn_1","queued":false}"#.utf8)
        }
        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?, personDecision: String?) async throws {}
        func detach() async {}
        func close() async {}
    }

    @Test func cloudPromptUsesPreparedCapabilityWithoutPublishingIt() async throws {
        let client = Client(), frames = RemoteAcpmuxObserverTests.Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "session_1", cloudTurn: .init(state: { client.calls.withLock { $0.append("state") }; return Data("verified-state".utf8) }, capture: { session, _, prepared, state in
            #expect(String(decoding: state, as: UTF8.self) == "verified-state")
            #expect(session == "session_1")
            #expect(String(decoding: prepared, as: UTF8.self).contains("turn_1"))
            return Data("scoped-capability".utf8)
        }))
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"session_1","prompt":[{"type":"text","text":"hello"}]}}"#) { _ in }
        try await waitForReply(frames)
        #expect(client.calls.withLock { $0 } == ["state", "prepare", "fenced"])
        #expect(frames.reply(7)?["result"] != nil)
        let reply = try JSONSerialization.data(withJSONObject: frames.reply(7) ?? [:])
        #expect(!String(decoding: reply, as: UTF8.self).contains("scoped-capability"))
        wire.cancel(code: 1000, reason: "test complete")
    }

    @Test func ownerCaptureFailureNeverFallsBackToAnUnfencedPrompt() async throws {
        let client = Client(), frames = RemoteAcpmuxObserverTests.Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "session_1", cloudTurn: .init(state: { client.calls.withLock { $0.append("state") }; return Data("verified-state".utf8) }, capture: { _, _, _, _ in
            throw AgentSessionRemoteError(code: "capture.failed", message: "Capture failed")
        }))
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"session_1","prompt":[{"type":"text","text":"hello"}]}}"#) { _ in }
        try await waitForReply(frames)
        #expect(client.calls.withLock { $0 } == ["state", "prepare", "abandon"])
        #expect(frames.reply(7)?["error"] != nil)
        wire.cancel(code: 1000, reason: "test complete")
    }

    @Test func acceptedRetryDoesNotCaptureOrDispatchTwice() async throws {
        let client = Client(replay: true), frames = RemoteAcpmuxObserverTests.Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "session_1", cloudTurn: .init(state: { client.calls.withLock { $0.append("state") }; return Data("verified-state".utf8) }, capture: { _, _, _, _ in
            Issue.record("An accepted prompt must not mint a second capability")
            throw CancellationError()
        }))
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"session_1","prompt":[{"type":"text","text":"hello"}],"_meta":{"acpmux":{"promptId":"prompt_1"}}}}"#) { _ in }
        try await waitForReply(frames)
        #expect(client.calls.withLock { $0 } == ["state", "prepare"])
        #expect(frames.reply(7)?["result"] != nil)
        wire.cancel(code: 1000, reason: "test complete")
    }

    @Test func uncertainSubmissionNeverAbandonsItsReservation() async throws {
        let client = Client(submissionFails: true), frames = RemoteAcpmuxObserverTests.Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "session_1", cloudTurn: .init(state: {
            client.calls.withLock { $0.append("state") }
            return Data("verified-state".utf8)
        }, capture: { _, _, _, _ in Data("scoped-capability".utf8) }))
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"session_1","prompt":[{"type":"text","text":"hello"}]}}"#) { _ in }
        try await waitForReply(frames)
        #expect(client.calls.withLock { $0 } == ["state", "prepare", "fenced"])
        #expect(frames.reply(7)?["error"] != nil)
        wire.cancel(code: 1000, reason: "test complete")
    }

    private func waitForReply(_ frames: RemoteAcpmuxObserverTests.Frames) async throws {
        for _ in 0..<200 where frames.reply(7) == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(frames.reply(7) != nil)
    }
}
