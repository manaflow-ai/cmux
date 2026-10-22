import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// cx-0q7o: a question answered in the pane for a chat on another machine goes through this wire
/// to that machine's session daemon. The wire dropped the answers and sent a bare allow, so that
/// machine's acpmux could never count the answer, whatever proof the pane made (Leo, 2026-10-21:
/// "approve this on the Mac app" for every question answered on huge-blue).
@Suite(.timeLimit(.minutes(1)))
struct RemoteAcpmuxWireAnswersTests {
    /// The owning session daemon's side, writable, recording each answer.
    nonisolated final class AnsweringClient: AgentSessionRemoteClient {
        let answers = Mutex<[(option: String, answers: Data?, nonce: String?, proof: String?)]>([])
        let isReadOnly = false

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            Data(#"{"session":{"sessionId":"sub"},"events":[],"hasMore":false,"lastSeq":0}"#.utf8)
        }
        func events(_ page: AgentSessionPage) async throws -> Data { Data(#"{"events":[],"hasMore":false,"lastSeq":0}"#.utf8) }
        func prompt(id: String, text: String) async throws -> Data { Data("{}".utf8) }
        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, decisionNonce: String?, personDecision: String?) async throws {
            self.answers.withLock { $0.append((option, answers, decisionNonce, personDecision)) }
        }
        func detach() async {}
        func close() async {}
    }

    @Test func theWireTakesAQuestionsAnswersToThatMachine() async throws {
        let client = AnsweringClient()
        let wire = RemoteAcpmuxWire(client: client, session: "sub")
        let (frames, continuation) = AsyncStream.makeStream(of: String.self)
        try await wire.open(onFrame: { continuation.yield($0) }, onClose: { _, _ in continuation.finish() })
        let nonce = String(repeating: "ab", count: 32), proof = String(repeating: "cd", count: 32)

        // Answers that are not an object are refused here; nothing reaches that machine.
        wire.send(#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/permission_respond","params":{"sessionId":"sub","permissionId":"p1","optionId":"yes","answers":"B"}}"#) { _ in }
        wire.send(#"{"jsonrpc":"2.0","id":2,"method":"_acpmux/permission_respond","params":{"sessionId":"sub","permissionId":"p1","optionId":"yes","answers":{"Which one?":"B"},"_meta":{"acpmux":{"decisionNonce":"\#(nonce)","personDecision":"\#(proof)"}}}}"#) { _ in }
        var replies: [Int: [String: Any]] = [:]
        for await frame in frames {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
            if let id = object["id"] as? Int { replies[id] = object }
            if replies.count == 2 { break }
        }
        #expect(replies[1]?["error"] != nil, "\(String(describing: replies[1]))")
        #expect(replies[2]?["result"] != nil, "\(String(describing: replies[2]))")
        let sent = client.answers.withLock { $0 }
        #expect(sent.count == 1)
        let answer = try #require(sent.first)
        #expect(answer.option == "yes")
        #expect(answer.nonce == nonce && answer.proof == proof)
        let answers = try #require(answer.answers)
        #expect(try JSONSerialization.jsonObject(with: answers) as? [String: String] == ["Which one?": "B"])
    }
}
