import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A reply to a Cloud chat whose machine is busy or just resumed: the daemon there did not take it
/// within the call's deadline. The wire said "Not sent: timed out: agent-session-prompt", the prompt
/// ran anyway, and the page's Retry of it hung at Sending (cmux#55671). It now goes again under the
/// same prompt id (acpmux runs an id once) until the daemon answers it, as a local chat's does.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RemoteAcpmuxWirePromptDeliveryTests {
    private actor Client: AgentSessionRemoteClient {
        nonisolated let isReadOnly = false
        /// What each prompt call answers, in order; past the end, the acceptance.
        private var failures: [any Error]
        private(set) var prompts: [String] = []
        private var gate: CheckedContinuation<Void, Never>?
        private let holdFirst: Bool

        init(failures: [any Error], holdFirst: Bool = false) {
            self.failures = failures
            self.holdFirst = holdFirst
        }

        func prompt(id: String, text: String) async throws -> Data {
            prompts.append(id)
            if holdFirst, prompts.count == 1 { await withCheckedContinuation { gate = $0 } }
            if !failures.isEmpty { throw failures.removeFirst() }
            return Data(#"{"prompt_id":"\#(id)","turn_id":"t1","queued":true,"state":"queued"}"#.utf8)
        }

        func release() { gate?.resume(); gate = nil }
        func attach(_ page: AgentSessionPage, events: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data { Data("{}".utf8) }
        func events(_ page: AgentSessionPage) async throws -> Data { Data("{}".utf8) }
        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?, personDecision: String?) async throws {}
        func detach() async {}
        func close() async {}
    }

    private static func prompt(_ id: Int, promptID: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"session/prompt","params":{"sessionId":"s","prompt":[{"type":"text","text":"Yes, find both causes"}],"_meta":{"acpmux":{"promptId":"\#(promptID)"}}}}"#
    }

    @Test func aPromptTheDaemonDidNotTakeYetGoesAgainUnderItsIdUntilItIsTaken() async throws {
        let client = Client(failures: [
            DaemonError.timedOut("agent-session-prompt (no reply within 10.0 seconds)"),
            AgentSessionRemoteError(code: "agent_session.timeout", message: "acpmux did not answer in time"),
            AgentSessionRemoteError(code: "agent_session.limit", message: "the agent tab could not attach now; try again"),
        ])
        let wire = RemoteAcpmuxWire(client: client, session: "s")
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        try await wire.open(onFrame: { inbox.deliver([$0]) }, onClose: { _, _ in })
        wire.send(Self.prompt(4, promptID: "p-reply")) { _ in }
        let accepted = await inbox.frame(containing: "_acpmux/prompt_accepted")
        #expect(accepted.contains("\"queued\":true"))
        let reply = await inbox.frame(containing: "\"id\":4")
        #expect(!reply.contains("\"error\""), "\(reply)")
        #expect(await client.prompts == ["p-reply", "p-reply", "p-reply", "p-reply"])
        wire.cancel(code: 1000, reason: "test complete")
    }

    @Test func aRetryOfAPromptStillOnItsWayJoinsItInsteadOfRacingIt() async throws {
        let client = Client(failures: [], holdFirst: true)
        let wire = RemoteAcpmuxWire(client: client, session: "s")
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        try await wire.open(onFrame: { inbox.deliver([$0]) }, onClose: { _, _ in })
        wire.send(Self.prompt(1, promptID: "p-same")) { _ in }
        while await client.prompts.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        wire.send(Self.prompt(2, promptID: "p-same")) { _ in }
        while wire.joinedDeliveries == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await client.release()
        let first = await inbox.frame(containing: "\"id\":1")
        let second = await inbox.frame(containing: "\"id\":2")
        #expect(!first.contains("\"error\"") && !second.contains("\"error\""))
        #expect(await client.prompts == ["p-same"])
        wire.cancel(code: 1000, reason: "test complete")
    }

    @Test func aPromptTheDaemonNeverTakesFailsOnceItsPatienceIsSpent() async throws {
        #expect(RemoteAcpmuxWire.unansweredPromptPatience > .seconds(60), "past the page's failMs, so the page fails it first")
        #expect(RemoteAcpmuxWire.unansweredPromptPatience < .seconds(5 * 60))
    }

    @Test func aRefusalOfThePromptItselfIsAnsweredAtOnce() async throws {
        let client = Client(failures: [AgentSessionRemoteError(code: "agent_session.refused", message: "acpmux refused the request")])
        let wire = RemoteAcpmuxWire(client: client, session: "s")
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        try await wire.open(onFrame: { inbox.deliver([$0]) }, onClose: { _, _ in })
        wire.send(Self.prompt(3, promptID: "p-refused")) { _ in }
        let reply = await inbox.frame(containing: "\"id\":3")
        #expect(reply.contains("agent_session.refused"))
        #expect(await client.prompts == ["p-refused"])
        wire.cancel(code: 1000, reason: "test complete")
    }
}
