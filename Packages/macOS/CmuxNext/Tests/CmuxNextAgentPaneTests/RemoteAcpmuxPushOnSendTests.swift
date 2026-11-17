import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// Push on send: a Cloud chat whose folder came from this Mac runs its ``RemoteAcpmuxWire/BeforeSend`` (the files
/// changed here reach the machine, `cmux link sync on-send`) right before each prompt goes, and a note it answers
/// (files still arriving) goes with the prompt as hidden context for the agent. Sends keep their order, and a wire
/// without it sends as before.
@Suite(.timeLimit(.minutes(1))) struct RemoteAcpmuxPushOnSendTests {
    nonisolated final class FakeClient: AgentSessionRemoteClient {
        let calls = Mutex<[String]>([])
        let isReadOnly = false

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            Data(#"{"session":{"sessionId":"acp_1"},"events":[],"hasMore":false,"lastSeq":3}"#.utf8)
        }

        func events(_ page: AgentSessionPage) async throws -> Data { Data(#"{"events":[],"hasMore":false,"lastSeq":3}"#.utf8) }
        func prompt(id: String, text: String) async throws -> Data {
            calls.withLock { $0.append("prompt \(id)") }
            return Data(#"{"prompt_id":"x","turn_id":"t","queued":false}"#.utf8)
        }
        func prompt(id: String, text: String, steer: Bool, context: String?) async throws -> Data {
            calls.withLock { $0.append("prompt \(id) context \(context ?? "none")") }
            return Data(#"{"prompt_id":"x","turn_id":"t","queued":false}"#.utf8)
        }
        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                        personDecision: String?) async throws {}
        func detach() async {}
        func close() async {}
    }

    typealias Frames = RemoteAcpmuxObserverTests.Frames

    static func attached(beforeSend: RemoteAcpmuxWire.BeforeSend?) async throws -> (RemoteAcpmuxWire, FakeClient, Frames) {
        let client = FakeClient()
        let frames = Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "sub", beforeSend: beforeSend)
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        wire.send(#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/attach","params":{"sessionId":"sub"}}"#) { _ in }
        try await waitUntil { frames.reply(1) != nil }
        return (wire, client, frames)
    }

    static func prompt(_ wire: RemoteAcpmuxWire, id: Int, promptID: String) {
        wire.send(#"{"jsonrpc":"2.0","id":\#(id),"method":"session/prompt","params":{"sessionId":"sub","prompt":[{"type":"text","text":"go"}],"_meta":{"acpmux":{"promptId":"\#(promptID)"}}}}"#) { _ in }
    }

    @Test func aNoteForTheAgentGoesWithThePromptAfterThePush() async throws {
        let pushes = Mutex<[String]>([])
        let (wire, client, frames) = try await Self.attached { session in
            pushes.withLock { $0.append(session) }
            return "Files changed on the person's Mac are still arriving in this folder."
        }
        Self.prompt(wire, id: 2, promptID: "p1")
        try await Self.waitUntil { frames.reply(2) != nil }
        #expect(pushes.withLock { $0 } == ["sub"])
        #expect(client.calls.withLock { $0 } == ["prompt p1 context Files changed on the person's Mac are still arriving in this folder."])
        #expect(frames.reply(2)?["result"] != nil)
    }

    @Test func nothingArrivingSendsThePromptAlone() async throws {
        let (wire, client, frames) = try await Self.attached { _ in nil }
        Self.prompt(wire, id: 2, promptID: "p1")
        try await Self.waitUntil { frames.reply(2) != nil }
        #expect(client.calls.withLock { $0 } == ["prompt p1 context none"])
    }

    /// A send whose files take a moment is never overtaken by the person's next message.
    @Test func aSlowPushKeepsTheSendsInOrder() async throws {
        let (wire, client, frames) = try await Self.attached { _ in
            let first = Self.firstPush.withLock { taken in defer { taken = true }; return !taken }
            if first { try? await Task.sleep(for: .milliseconds(200)) }
            return nil
        }
        Self.prompt(wire, id: 2, promptID: "p1")
        Self.prompt(wire, id: 3, promptID: "p2")
        try await Self.waitUntil { frames.reply(2) != nil && frames.reply(3) != nil }
        #expect(client.calls.withLock { $0 } == ["prompt p1 context none", "prompt p2 context none"])
    }

    static let firstPush = Mutex(false)

    /// A send that never ends holds the next one only for the bound, never for good.
    @Test func aHungEarlierSendHoldsTheNextOnlyForTheBound() async throws {
        // task-owner: stands for a send whose prompt never answers; cancelled at the test's end
        let hung = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        defer { hung.cancel() }
        let clock = ContinuousClock()
        let started = clock.now
        await RemoteAcpmuxWire.settled(hung, within: .milliseconds(100))
        let waited = clock.now - started
        #expect(waited >= .milliseconds(100) && waited < .seconds(5))
        await RemoteAcpmuxWire.settled(Task {}, within: .seconds(30))
    }

    private static func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
