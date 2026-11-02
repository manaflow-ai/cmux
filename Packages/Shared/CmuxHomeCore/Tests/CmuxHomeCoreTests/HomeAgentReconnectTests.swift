import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

@MainActor struct HomeAgentReconnectTests {
    @Test func aPushedConversationPageRefreshesAgentReports() async throws {
        let source = AgentReportRecoverySource()
        let store = HomeStore(source: source)
        store.start()
        defer { store.stop() }
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        let conversation = ConversationID("conv_aziz")
        await store.open(conversation)
        await waitUntil { store.agentMessageReads[conversation] == nil }
        let question = try #require(store.transcript(for: conversation).first?.messageID)
        await source.finishReport(in: conversation, answering: question)
        let page = try await source.snapshot(of: conversation, tail: 100)
        store.handle(.conversationPage(page))
        await waitUntil { store.transcript(for: conversation).contains { $0.plainText.contains("Recovered report") } }
        #expect(store.transcript(for: conversation).filter(\.isReadOnly).count == 1)
    }

    @Test(arguments: [false, true])
    func reportMissedWhileDisconnectedAppearsOnRecovery(ownerOnly: Bool) async throws {
        let source = AgentReportRecoverySource()
        let store = HomeStore(source: source)
        store.start()
        defer { store.stop() }
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        let conversation = ConversationID("conv_aziz")
        await store.open(conversation)
        await waitUntil { store.agentMessageReads[conversation] == nil }
        let question = try #require(store.transcript(for: conversation).first?.messageID)
        if !ownerOnly { store.handle(.connection(.offline(since: Date()))) }
        await source.finishReport(in: conversation, answering: question)
        #expect(!store.transcript(for: conversation).contains { $0.plainText.contains("Recovered report") })
        store.handle(ownerOnly ? .ownerRecovered : .connection(.online))
        await waitUntil { store.transcript(for: conversation).contains { $0.plainText.contains("Recovered report") } }
        #expect(store.transcript(for: conversation).filter(\.isReadOnly).count == 1)
    }
}

private actor AgentReportRecoverySource: HomeSource {
    let inner = MockHomeSource(options: .immediate)
    private var reports: [HomeAgentRun] = []

    func finishReport(in conversation: ConversationID, answering question: MessageID) {
        reports = [.init(conversation: conversation, id: "reports:assignment", author: ParticipantID("agent_mux"),
                         turn: nil, answers: [question], threadRoot: nil, revision: 1, messages: [
                            .init(id: "report:a1:1", sequence: 1, revision: 1, peer: "a1", outgoing: false,
                                  text: "Recovered report", date: Date())
                         ])]
    }

    func agentRuns(of conversation: ConversationID, window: HomeAgentRunWindow) async -> [HomeAgentRun] { reports }
    func events() async -> AsyncStream<HomeEvent> { await inner.events() }
    func inbox() async throws -> InboxSnapshot { try await inner.inbox() }
    func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        try await inner.snapshot(of: conversation, tail: tail)
    }
    func history(of conversation: ConversationID, before seq: Seq, limit: Int) async throws -> [Message] {
        try await inner.history(of: conversation, before: seq, limit: limit)
    }
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { try await inner.search(query, limit: limit) }
    func resolve(_ contact: ContactAddress) async throws -> ContactResolution { try await inner.resolve(contact) }
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult { try await inner.submit(intent) }
}
