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
        let badReplay: String?
        let turnsSupported: Bool
        func supportsCloudTurns() async -> Bool { turnsSupported }
        init(replay: Bool = false, submissionFails: Bool = false, turnsSupported: Bool = true, badReplay: String? = nil) {
            self.badReplay = badReplay
            self.replay = replay; self.submissionFails = submissionFails; self.turnsSupported = turnsSupported
        }
        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data { Data("{}".utf8) }
        func events(_ page: AgentSessionPage) async throws -> Data { Data("{}".utf8) }
        func prompt(id: String, text: String) async throws -> Data {
            calls.withLock { $0.append("unfenced") }
            return Data("{}".utf8)
        }
        func prepareCloudTurn(id: String, scope: Data) async throws -> Data {
            #expect(String(decoding: scope, as: UTF8.self) == #"{"turn":"prompt_1","generation":7,"attemptId":"attempt_1"}"#)
            calls.withLock { $0.append("prepare") }
            var prepared: [String: Any] = ["session":"session_1", "turn":"prompt_1", "generation":7, "attempt_id":"attempt_1"]
            if replay {
                prepared["accepted"] = ["prompt_id":"prompt_1", "turn_id":"prompt_1", "queued":false]
                if badReplay == "generation" { prepared["generation"] = 6 }
                if badReplay == "attempt" { prepared["attempt_id"] = "another" }
            }
            return try JSONSerialization.data(withJSONObject: prepared)
        }
        func abandonCloudTurn(id: String, scope: Data) async throws { calls.withLock { $0.append("abandon") } }
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

    @Test func enrolledCloudMachineCannotSendWithoutTurnSupport() async throws {
        let client = Client(turnsSupported: false), frames = RemoteAcpmuxObserverTests.Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "session_1", cloudTurn: .init(state: { _, _ in
            Issue.record("An unsupported acpmux must not start the capture handshake")
            throw CancellationError()
        }, capture: { _, _, _, _ in throw CancellationError() }))
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"session_1","prompt":[{"type":"text","text":"hello"}],"_meta":{"acpmux":{"promptId":"prompt_1"}}}}"#) { _ in }
        try await waitForReply(frames)
        #expect(client.calls.withLock { $0 }.isEmpty)
        #expect(frames.reply(7)?["error"] != nil)
        wire.cancel(code: 1000, reason: "test complete")
    }

    @Test func ordinaryRemoteMachineKeepsItsPromptPath() async throws {
        let client = Client(turnsSupported: false), frames = RemoteAcpmuxObserverTests.Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "session_1")
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"session_1","prompt":[{"type":"text","text":"hello"}],"_meta":{"acpmux":{"promptId":"prompt_1"}}}}"#) { _ in }
        try await waitForReply(frames)
        #expect(client.calls.withLock { $0 } == ["unfenced"])
        #expect(frames.reply(7)?["result"] != nil)
        wire.cancel(code: 1000, reason: "test complete")
    }

    @Test func cloudPromptUsesPreparedCapabilityWithoutPublishingIt() async throws {
        let client = Client(), frames = RemoteAcpmuxObserverTests.Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "session_1", cloudTurn: .init(state: { _, _ in client.calls.withLock { $0.append("state") }; return Data(#"{"turn":"prompt_1","generation":7,"attemptId":"attempt_1"}"#.utf8) }, capture: { session, _, prepared, state in
            #expect(String(decoding: state, as: UTF8.self) == #"{"turn":"prompt_1","generation":7,"attemptId":"attempt_1"}"#)
            #expect(session == "session_1")
            #expect(String(decoding: prepared, as: UTF8.self).contains("prompt_1"))
            return Data("scoped-capability".utf8)
        }))
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"session_1","prompt":[{"type":"text","text":"hello"}],"_meta":{"acpmux":{"promptId":"prompt_1"}}}}"#) { _ in }
        try await waitForReply(frames)
        #expect(client.calls.withLock { $0 } == ["state", "prepare", "fenced"])
        #expect(frames.reply(7)?["result"] != nil)
        let reply = try JSONSerialization.data(withJSONObject: frames.reply(7) ?? [:])
        #expect(!String(decoding: reply, as: UTF8.self).contains("scoped-capability"))
        wire.cancel(code: 1000, reason: "test complete")
    }

    @Test func ownerCaptureFailureNeverFallsBackToAnUnfencedPrompt() async throws {
        let client = Client(), frames = RemoteAcpmuxObserverTests.Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "session_1", cloudTurn: .init(state: { _, _ in client.calls.withLock { $0.append("state") }; return Data(#"{"turn":"prompt_1","generation":7,"attemptId":"attempt_1"}"#.utf8) }, capture: { _, _, _, _ in
            throw AgentSessionRemoteError(code: "capture.failed", message: "Capture failed")
        }))
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"session_1","prompt":[{"type":"text","text":"hello"}],"_meta":{"acpmux":{"promptId":"prompt_1"}}}}"#) { _ in }
        try await waitForReply(frames)
        #expect(client.calls.withLock { $0 } == ["state", "prepare", "abandon"])
        #expect(frames.reply(7)?["error"] != nil)
        wire.cancel(code: 1000, reason: "test complete")
    }

    @Test func acceptedRetryDoesNotCaptureOrDispatchTwice() async throws {
        let client = Client(replay: true), frames = RemoteAcpmuxObserverTests.Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "session_1", cloudTurn: .init(state: { _, _ in client.calls.withLock { $0.append("state") }; return Data(#"{"turn":"prompt_1","generation":7,"attemptId":"attempt_1"}"#.utf8) }, capture: { _, _, _, _ in
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

    @Test func staleReplayCannotAcknowledgeAnotherGenerationOrAttempt() async throws {
        for mismatch in ["generation", "attempt"] {
            let client = Client(replay: true, badReplay: mismatch), frames = RemoteAcpmuxObserverTests.Frames()
            let wire = RemoteAcpmuxWire(client: client, session: "session_1", cloudTurn: .init(state: { _, _ in
                Data(#"{"turn":"prompt_1","generation":7,"attemptId":"attempt_1"}"#.utf8)
            }, capture: { _, _, _, _ in Issue.record("Stale replay must never capture"); throw CancellationError() }))
            try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
            wire.send(#"{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"session_1","prompt":[{"type":"text","text":"hello"}],"_meta":{"acpmux":{"promptId":"prompt_1"}}}}"#) { _ in }
            try await waitForReply(frames)
            #expect(frames.reply(7)?["error"] != nil)
            #expect(client.calls.withLock { $0 } == ["prepare", "abandon"])
            wire.cancel(code: 1000, reason: "test complete")
        }
    }

    @Test func uncertainSubmissionNeverAbandonsItsReservation() async throws {
        let client = Client(submissionFails: true), frames = RemoteAcpmuxObserverTests.Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "session_1", cloudTurn: .init(state: { _, _ in
            client.calls.withLock { $0.append("state") }
            return Data(#"{"turn":"prompt_1","generation":7,"attemptId":"attempt_1"}"#.utf8)
        }, capture: { _, _, _, _ in Data("scoped-capability".utf8) }))
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"session_1","prompt":[{"type":"text","text":"hello"}],"_meta":{"acpmux":{"promptId":"prompt_1"}}}}"#) { _ in }
        try await waitForReply(frames)
        #expect(client.calls.withLock { $0 } == ["state", "prepare", "fenced"])
        #expect(frames.reply(7)?["error"] != nil)
        wire.cancel(code: 1000, reason: "test complete")
    }

    private func waitForReply(_ frames: RemoteAcpmuxObserverTests.Frames) async throws {
        for _ in 0..<200 where frames.reply(7) == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(frames.reply(7) != nil)
    }

    @Test func staleCloudConnectionClosesSoThePaneCanReattach() async throws {
        let client = Client(), frames = RemoteAcpmuxObserverTests.Frames()
        let (closed, continuation) = AsyncStream<Int>.makeStream()
        let wire = RemoteAcpmuxWire(client: client, session: "session_1", cloudTurn: .init(state: { _, _ in
            throw AgentSessionRemoteError(code: "cloud.turn.connection", message: "The Cloud machine changed")
        }, capture: { _, _, _, _ in Issue.record("A stale attachment must not capture"); return Data() }))
        try await wire.open(onFrame: { frames.append($0) }, onClose: { code, _ in continuation.yield(code) })
        wire.send(#"{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"session_1","prompt":[{"type":"text","text":"hello"}],"_meta":{"acpmux":{"promptId":"prompt_1"}}}}"#) { _ in }
        for await code in closed { #expect(code == 1012); break }
        #expect(frames.reply(7)?["error"] != nil)
        #expect(client.calls.withLock { $0 }.isEmpty)
        continuation.finish()
    }
}
