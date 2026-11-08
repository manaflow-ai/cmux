import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// Cloud multiplayer (lane C) on a chat of another machine: the page's steer reaches the owning
/// daemon as a steer (the owner's and a team member's go into the running turn), the daemon's
/// answer says whether it steered or is held for the owner, and the owner's Approve and Decline of
/// a held guest prompt reach that machine. Before, the wire dropped the steer, so every prompt to a
/// Cloud chat queued behind the running turn, and Approve had no route there at all.
@Suite(.timeLimit(.minutes(1))) struct RemoteAcpmuxSteerTests {
    nonisolated final class FakeClient: AgentSessionRemoteClient {
        let calls = Mutex<[String]>([])
        let answer: String
        let isReadOnly = false

        init(answer: String) { self.answer = answer }

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            Data(#"{"session":{"sessionId":"acp_1"},"events":[],"hasMore":false,"lastSeq":3}"#.utf8)
        }

        func events(_ page: AgentSessionPage) async throws -> Data { Data(#"{"events":[],"hasMore":false,"lastSeq":3}"#.utf8) }
        func prompt(id: String, text: String) async throws -> Data {
            calls.withLock { $0.append("prompt \(id)") }
            return Data(answer.utf8)
        }
        func prompt(id: String, text: String, steer: Bool) async throws -> Data {
            calls.withLock { $0.append("prompt \(id) steer \(steer)") }
            return Data(answer.utf8)
        }
        func queueApprove(promptID: String, turnID: String, revision: UInt64) async throws -> Data {
            calls.withLock { $0.append("approve \(promptID) \(turnID) \(revision)") }
            return Data("{}".utf8)
        }
        func queueDecline(promptID: String) async throws -> Data {
            calls.withLock { $0.append("decline \(promptID)") }
            return Data("{}".utf8)
        }
        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                        personDecision: String?) async throws {}
        func detach() async {}
        func close() async {}
    }

    typealias Frames = RemoteAcpmuxObserverTests.Frames

    static func attached(answer: String) async throws -> (RemoteAcpmuxWire, FakeClient, Frames) {
        let client = FakeClient(answer: answer)
        let frames = Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "sub")
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/attach","params":{"sessionId":"sub"}}"#) { _ in }
        try await waitUntil { frames.reply(1) != nil }
        return (wire, client, frames)
    }

    @Test func aSteerFromThePageReachesTheMachineAsASteer() async throws {
        let (wire, client, frames) = try await Self.attached(answer: #"{"prompt_id":"p1","turn_id":"t1","queued":false,"state":"steered","awaiting_owner":false}"#)
        wire.send(#"{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"sub","prompt":[{"type":"text","text":"also the tests"}],"_meta":{"acpmux":{"promptId":"p1","steer":true}}}}"#) { _ in }
        wire.send(#"{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sub","prompt":[{"type":"text","text":"later"}],"_meta":{"acpmux":{"promptId":"p2"}}}}"#) { _ in }
        try await Self.waitUntil { frames.reply(2) != nil && frames.reply(3) != nil }
        #expect(client.calls.withLock { $0 }.contains("prompt p1 steer true"))
        #expect(client.calls.withLock { $0 }.contains("prompt p2 steer false"))
        let accepted = frames.notifications("_acpmux/prompt_accepted").compactMap { $0["params"] as? [String: Any] }
        #expect(accepted.first { $0["promptId"] as? String == "p1" }?["state"] as? String == "steered")
    }

    @Test func aHeldPromptSaysItWaitsForTheOwner() async throws {
        let (wire, _, frames) = try await Self.attached(answer: #"{"prompt_id":"g1","turn_id":"t2","queued":true,"state":"queued","awaiting_owner":true}"#)
        wire.send(#"{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"sub","prompt":[{"type":"text","text":"hi"}],"_meta":{"acpmux":{"promptId":"g1","steer":true}}}}"#) { _ in }
        try await Self.waitUntil { !frames.notifications("_acpmux/prompt_accepted").isEmpty }
        let params = try #require(frames.notifications("_acpmux/prompt_accepted").first?["params"] as? [String: Any])
        #expect(params["awaitingOwner"] as? Bool == true)
        #expect(params["queued"] as? Bool == true)
    }

    @Test func theOwnersApproveAndDeclineReachTheMachine() async throws {
        let (wire, client, frames) = try await Self.attached(answer: "{}")
        wire.send(#"{"jsonrpc":"2.0","id":2,"method":"_acpmux/queue_approve","params":{"sessionId":"sub","promptId":"g1","turnId":"t2","revision":0}}"#) { _ in }
        wire.send(#"{"jsonrpc":"2.0","id":3,"method":"_acpmux/queue_decline","params":{"sessionId":"sub","promptId":"g2"}}"#) { _ in }
        wire.send(#"{"jsonrpc":"2.0","id":4,"method":"_acpmux/queue_approve","params":{"sessionId":"acp_other","promptId":"g3","turnId":"t","revision":0}}"#) { _ in }
        try await Self.waitUntil { (2...4).allSatisfy { frames.reply($0) != nil } }
        #expect(frames.reply(2)?["result"] != nil)
        #expect(frames.reply(3)?["result"] != nil)
        #expect(frames.reply(4)?["error"] != nil)
        #expect(Set(client.calls.withLock { $0 }) == ["approve g1 t2 0", "decline g2"])
    }

    private static func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
