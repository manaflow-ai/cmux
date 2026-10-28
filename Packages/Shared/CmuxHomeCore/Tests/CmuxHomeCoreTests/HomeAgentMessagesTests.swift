import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

struct HomeAgentMessagesTests {
    let conversation = ConversationID("conversation")
    let chief = ParticipantID("agent_mux")
    let date = Date(timeIntervalSince1970: 100)

    func message(_ id: String = "report", revision: UInt64, text: String) -> HomeAgentRun.Message {
        .init(id: id, sequence: 1, revision: revision, peer: "a1", outgoing: false, text: text, date: date)
    }

    func run(revision: UInt64, answers: [MessageID] = [MessageID("question")],
             messages: [HomeAgentRun.Message]) -> HomeAgentRun {
        .init(conversation: conversation, id: "run", author: chief, turn: nil,
              answers: answers, threadRoot: MessageID("thread"), revision: revision, messages: messages)
    }

    func question(_ id: String = "question") -> TranscriptItem {
        .init(key: IdempotencyKey(id), seq: 1, author: ParticipantID("user"), parts: [.text(id)],
              createdAt: date, delivery: .committed, messageID: MessageID(id))
    }

    @Test func duplicateFirstSnapshotKeepsNewestStepAndCanBeAppliedAgain() throws {
        var book = HomeAgentMessages()
        let fullText = String(repeating: "Full message 🦀\n", count: 1000)
        let update = run(revision: 5, messages: [message(revision: 5, text: fullText), message(revision: 1, text: "old")])
        #expect(book.apply(update))
        #expect(!book.apply(update))
        let rows = book.inserting(into: [question()], summary: nil)
        #expect(rows.count == 2)
        let report = try #require(rows.last)
        #expect(report.plainText.hasSuffix(fullText))
        #expect(report.isReadOnly)
        #expect(report.messageID == nil)
    }

    @Test func staleSummaryCannotMoveRowsButCanFillAMissingStep() throws {
        var book = HomeAgentMessages()
        #expect(book.apply(run(revision: 10, messages: [message(revision: 10, text: "new")])))
        var stale = run(revision: 2, answers: [MessageID("other")], messages: [
            message(revision: 2, text: "old"), message("earlier", revision: 1, text: "earlier report")
        ])
        stale.threadRoot = MessageID("wrong-thread")
        #expect(book.apply(stale))
        let rows = book.inserting(into: [question(), question("other")], summary: nil)
        #expect(rows.count == 4)
        #expect(rows.last?.key == IdempotencyKey("other"))
        let reports = rows.filter(\.isReadOnly)
        #expect(reports.allSatisfy { $0.threadRoot == MessageID("thread") })
        #expect(reports.contains { $0.plainText.hasSuffix("new") })
        #expect(!reports.contains { $0.plainText.hasSuffix("old") })
    }

    @Test func newerSummaryCannotRegressAnIndividualStep() {
        var book = HomeAgentMessages()
        _ = book.apply(run(revision: 10, messages: [message(revision: 9, text: "new")]))
        _ = book.apply(run(revision: 11, answers: [MessageID("other")], messages: [message(revision: 2, text: "old")]))
        let rows = book.inserting(into: [question(), question("other")], summary: nil)
        #expect(rows.last?.plainText.hasSuffix("new") == true)
        #expect(rows[1].key == IdempotencyKey("other"))
    }

    @Test func hydrationWindowMatchesLoadedRepliesAndQuestions() {
        let loaded = Message(id: MessageID("question"), conversation: conversation, seq: 1,
                             clientMessageID: IdempotencyKey("reply-key"), author: chief,
                             parts: [.text("text")], createdAt: date)
        let window = HomeAgentRunWindow(messages: [loaded])
        #expect(window.oldestMessageAt == date)
        #expect(window.turnsByAuthor[chief] == [IdempotencyKey("reply-key")])
        #expect(window.contains(turn: "reply-key", answers: []))
        #expect(window.contains(turn: nil, answers: ["question"]))
        #expect(!window.contains(turn: "unloaded-key", answers: ["unloaded-question"]))
        #expect(HomeAgentRunWindow(messages: []).oldestMessageAt == nil)
    }

    @Test func unrelatedRunProgressDoesNotInvalidateMessageRows() {
        var book = HomeAgentMessages()
        #expect(!book.apply(run(revision: 1, messages: [])))
        #expect(book.apply(run(revision: 2, messages: [message(revision: 2, text: "report")])))
        #expect(!book.apply(run(revision: 3, messages: [])))
        #expect(!book.apply(run(revision: 4, messages: [message(revision: 4, text: "report")])))
        #expect(book.apply(run(revision: 5, messages: [message(revision: 5, text: "updated report")])))
        #expect(book.inserting(into: [question()], summary: nil).last?.plainText.hasSuffix("updated report") == true)
    }

    @Test func unversionedCloudStepUpdatesReplaceContentAtTheSameSequence() {
        var book = HomeAgentMessages()
        let running = run(revision: 0, messages: [message("tell", revision: 0, text: "Please check")])
        let refused = run(revision: 0, messages: [message("tell", revision: 0, text: "Please check\n[Error: outcome: refused]")])
        #expect(book.apply(running))
        #expect(book.apply(refused))
        #expect(!book.apply(refused))
        let rows = book.inserting(into: [question()], summary: nil)
        #expect(rows.count == 2)
        #expect(rows.last?.plainText.contains("outcome: refused") == true)
    }

    @Test func separateReportRecordFollowsTellBesideTheAssignment() {
        var book = HomeAgentMessages()
        var tell = run(revision: 1, messages: [.init(id: "tell", sequence: 1, revision: 1,
            peer: "a1", outgoing: true, text: "please check", date: date)])
        tell.id = "turn"
        tell.turn = IdempotencyKey("reply")
        var report = run(revision: 1, messages: [message(revision: 1, text: "checked")])
        report.id = "reports:turn"
        report.messages = report.messages.map { original in
            var next = original
            next.date = date.addingTimeInterval(1)
            return next
        }
        _ = book.apply(report)
        _ = book.apply(tell)
        let reply = TranscriptItem(key: IdempotencyKey("reply"), seq: 2, author: chief,
                                   parts: [.text("done")], createdAt: date, delivery: .committed)
        let rows = book.inserting(into: [question(), reply], summary: nil)
        #expect(rows.map(\.plainText) == ["question", "[agent_mux → a1]\nplease check", "[a1 → agent_mux]\nchecked", "done"])
    }

    @MainActor @Test func closeCancelsHydrationAndRejectsLateReports() async {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        defer { store.stop() }
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        let id = ConversationID("conv_aziz")
        await store.open(id)
        store.agentMessageReads[id]?.cancel()
        let read = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        store.agentMessageReads[id] = read
        store.close(id)
        #expect(read.isCancelled)
        await read.value
        var report = run(revision: 1, messages: [message(revision: 1, text: "late")])
        report.conversation = id
        store.applyAgentRun(report)
        #expect(store.agentMessageReads[id] == nil)
        #expect(store.agentMessages[id] == nil)
        #expect(store.transcript(for: id).isEmpty)
    }
}
