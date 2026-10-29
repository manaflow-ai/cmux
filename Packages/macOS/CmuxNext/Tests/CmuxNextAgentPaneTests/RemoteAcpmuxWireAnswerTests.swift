import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// An agent's question answered in the pane for a chat on another machine goes out through the
/// real ``RemoteAcpmuxWire``, which turns the page's `_acpmux/permission_respond` into the owning
/// session daemon's `agent-session-permission`. The answer must reach that daemon with its answers
/// and the proof over them: before, the wire dropped the answers and that machine's acpmux checked
/// the answers proof against a plain allow and refused it (Codex review of #23869, Leo 2026-10-21).
@Suite(.serialized)
@MainActor
struct RemoteAcpmuxWireAnswerTests {
    typealias Relayed = AgentPaneRelayedAllowTests

    /// One answer as the wire hands it to the daemon client.
    struct Answer: Sendable {
        var option: String
        var answers: Data?
        var annotations: Data?
        var nonce: String?
        var proof: String?
    }

    /// The owning session daemon's side of the chat: attaches at once, pushes what the test sends,
    /// and records each permission answer the wire makes.
    nonisolated final class DaemonClient: AgentSessionRemoteClient {
        private let handler = Mutex<(@Sendable (AgentSessionRemoteEvent) -> Void)?>(nil)
        private let answered = Mutex<(answers: [Answer], waiters: [CheckedContinuation<Answer, Never>])>(([], []))
        let isReadOnly = false

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            self.handler.withLock { $0 = handler }
            return Data(#"{"session":{"sessionId":"s"},"events":[],"hasMore":false,"lastSeq":0}"#.utf8)
        }

        func events(_ page: AgentSessionPage) async throws -> Data { Data(#"{"events":[],"hasMore":false,"lastSeq":0}"#.utf8) }
        func prompt(id: String, text: String) async throws -> Data { Data("{}".utf8) }
        func cancel() async throws {}

        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                        personDecision: String?) async throws {
            record(Answer(option: option, answers: answers, annotations: annotations, nonce: decisionNonce, proof: personDecision))
        }

        func detach() async {}
        func close() async {}

        func push(_ event: AgentSessionRemoteEvent) { handler.withLock { $0 }?(event) }

        private func record(_ answer: Answer) {
            let waiters = answered.withLock { state -> [CheckedContinuation<Answer, Never>] in
                state.answers.append(answer)
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume(returning: answer) }
        }

        /// The first answer the wire made.
        func answer() async -> Answer {
            await withCheckedContinuation { waiter in
                let found = answered.withLock { state -> Answer? in
                    if let first = state.answers.first { return first }
                    state.waiters.append(waiter)
                    return nil
                }
                if let found { waiter.resume(returning: found) }
            }
        }
    }

    @Test func anAnswerThroughTheRemoteWireReachesTheDaemonWithItsAnswersAndTheirProof() async throws {
        let machine = "machine-\(UUID().uuidString)"
        let key = try #require(AcpmuxSecretKey())
        AcpmuxRemotePersonKeys.shared.bind(machine: machine, instance: Relayed.instance, key: key)
        defer { AcpmuxRemotePersonKeys.shared.drop(machine: machine) }
        let approvals = AgentPaneRemoteApprovals(machineID: machine, label: "host") { nil }
        let client = DaemonClient()
        let wire = RemoteAcpmuxWire(client: client, session: "s")
        let route = AgentPaneRemoteRoute(machine: "host", approvals: approvals) { wire }
        let inbox = Relayed.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(.remote(route))
        _ = await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#])
        _ = await inbox.frame(containing: "\"origin\":\"remote\"")
        transport.sessions.add("s")
        _ = await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":1,"method":"_acpmux/attach","params":{"sessionId":"s"}}"#])
        _ = await inbox.frame(containing: "\"lastSeq\"")
        let pending = try JSONSerialization.jsonObject(with: Data(Relayed.pendingQuestion().utf8)) as? [String: Any]
        let request = try JSONSerialization.data(withJSONObject: try #require(pending?["params"]))
        client.push(.permission(request))
        _ = await inbox.frame(containing: "permission_pending")

        transport.gestures.record(click: true)
        let notes: [String: Any] = ["Which one?": ["preview": "[ B ]", "notes": "but narrower"]]
        let intent = try #require(Relayed.intent(option: "yes", answers: ["Which one?": "B"], annotations: notes))
        let ticket = try #require(transport.reserveGesture(intent))
        let frame = #"{"jsonrpc":"2.0","id":7,"method":"_acpmux/permission_respond","params":{"sessionId":"s","permissionId":"p1","optionId":"yes","answers":{"Which one?":"B"},"annotations":{"Which one?":{"preview":"[ B ]","notes":"but narrower"}},"_meta":{"cmuxGesture":"\#(ticket)"}}}"#
        let error = await transport.send(connection: id, frames: [frame])
        #expect(error == nil, "\(String(describing: error))")

        let answer = await client.answer()
        #expect(answer.option == "yes")
        #expect(answer.nonce == Relayed.nonce)
        #expect(answer.proof == key.decisionProof(instance: Relayed.instance, session: "s", permission: "p1", option: "yes",
                                                  nonce: Relayed.nonce, answers: ["Which one?": "B"], annotations: notes))
        let answers = try #require(answer.answers, "the wire dropped the answers, so that machine refuses the answer")
        #expect(try JSONSerialization.jsonObject(with: answers) as? [String: String] == ["Which one?": "B"])
        // Codex review of #25424: the chosen preview and notes go too, not dropped on the way.
        let sentNotes = try #require(answer.annotations, "the wire dropped the annotations, so the preview never reached the agent")
        #expect(try JSONSerialization.jsonObject(with: sentNotes) as? [String: [String: String]]
            == ["Which one?": ["preview": "[ B ]", "notes": "but narrower"]])
    }
}
