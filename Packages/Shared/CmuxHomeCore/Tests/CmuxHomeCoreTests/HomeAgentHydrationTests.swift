import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

@MainActor struct HomeAgentHydrationTests {
    @Test func deferredCloudSnapshotPreservesLiveRefusalAndFillsMissingSteps() async throws {
        let source = DeferredAgentSnapshotSource()
        let store = HomeStore(source: source)
        store.start()
        defer { store.stop() }
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        let conversation = ConversationID("conv_aziz")
        await store.open(conversation)
        await waitUntil { store.agentMessageReads[conversation] == nil }
        let question = try #require(store.transcript(for: conversation).first?.messageID)
        let questionKey = try #require(store.transcript(for: conversation).first?.key)
        let chief = ParticipantID("agent_mux")
        func run(_ text: String, missingStep: Bool = false) -> HomeAgentRun {
            var messages: [HomeAgentRun.Message] = [
                .init(id: "tell", sequence: 1, revision: 0, peer: "a1", outgoing: true,
                      text: text, date: Date(timeIntervalSince1970: 100))
            ]
            if missingStep {
                messages.append(.init(id: "report", sequence: 2, revision: 0, peer: "a1", outgoing: false,
                                      text: "Earlier report", date: Date(timeIntervalSince1970: 101)))
            }
            return .init(conversation: conversation, id: "run", author: chief, turn: nil,
                         answers: [question], revision: 0, messages: messages)
        }
        func live(_ update: HomeAgentRun) {
            store.handle(.live(.run(.init(conversation: conversation, author: chief, run: update.id,
                                         turn: nil, status: "running", agentRun: update))))
        }

        live(run("Pending tell"))
        await source.prepare([run("Pending tell", missingStep: true)], deferred: true)
        store.requestAgentMessages(conversation)
        let hydration = try #require(store.agentMessageReads[conversation])
        await source.waitForRead()
        live(run("Tell refused: agent cancelled"))
        await source.release()
        await hydration.value

        // The tell and the report fold into one row; open it to read both (a click on that row).
        let group = HomeAgentMessageRow.groupID(author: chief, anchor: questionKey)
        #expect(store.transcript(for: conversation).filter(\.isReadOnly).count == 1)
        store.toggleAgentMessages(group, in: conversation)
        #expect(store.isAgentMessagesExpanded(group, in: conversation))
        let hydrated = store.transcript(for: conversation).filter(\.isReadOnly)
        #expect(hydrated.count == 3)
        #expect(hydrated.contains { $0.plainText.hasSuffix("Tell refused: agent cancelled") })
        #expect(hydrated.contains { $0.plainText.hasSuffix("Earlier report") })
        #expect(!hydrated.contains { $0.plainText.hasSuffix("Pending tell") })

        // Protect only live changes concurrent with that read. A later no-clock
        // snapshot must still refresh an existing step (for example after reconnect).
        await source.prepare([run("Updated receipt after reconnect", missingStep: true)], deferred: false)
        store.requestAgentMessages(conversation)
        let refresh = try #require(store.agentMessageReads[conversation])
        await refresh.value
        #expect(store.transcript(for: conversation).contains { $0.plainText.hasSuffix("Updated receipt after reconnect") })
    }
}

private actor DeferredAgentSnapshotSource: HomeSource {
    let inner = MockHomeSource(options: .immediate)
    private var reports: [HomeAgentRun] = []
    private var deferred = false
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func prepare(_ reports: [HomeAgentRun], deferred: Bool) {
        self.reports = reports
        self.deferred = deferred
    }

    func waitForRead() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        pending?.resume()
        pending = nil
    }

    func agentRuns(of conversation: ConversationID, window: HomeAgentRunWindow) async -> [HomeAgentRun] {
        let snapshot = reports
        if deferred {
            deferred = false
            await withCheckedContinuation {
                pending = $0
                started?.resume()
                started = nil
            }
        }
        return snapshot
    }
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
