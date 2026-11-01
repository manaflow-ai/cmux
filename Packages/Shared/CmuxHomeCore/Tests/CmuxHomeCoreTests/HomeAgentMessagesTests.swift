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
        let changed1 = book.apply(update)
        #expect(changed1)
        let changed2 = book.apply(update)
        #expect(!changed2)
        let rows = book.inserting(into: [question()], summary: nil)
        #expect(rows.count == 2)
        let report = try #require(rows.last)
        #expect(report.plainText.hasSuffix(fullText))
        #expect(report.isReadOnly)
        #expect(report.messageID == nil)
    }

    @Test func staleSummaryCannotMoveRowsButCanFillAMissingStep() throws {
        var book = HomeAgentMessages()
        let changed3 = book.apply(run(revision: 10, messages: [message(revision: 10, text: "new")]))
        #expect(changed3)
        var stale = run(revision: 2, answers: [MessageID("other")], messages: [
            message(revision: 2, text: "old"), message("earlier", revision: 1, text: "earlier report")
        ])
        stale.threadRoot = MessageID("wrong-thread")
        let changed4 = book.apply(stale)
        #expect(changed4)
        let rows = book.inserting(into: [question(), question("other")], summary: nil,
                                  expanded: [HomeAgentMessageRow.groupID(author: chief, anchor: IdempotencyKey("question"))])
        #expect(rows.count == 5)
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
        let changed5 = book.apply(run(revision: 1, messages: []))
        #expect(!changed5)
        let changed6 = book.apply(run(revision: 2, messages: [message(revision: 2, text: "report")]))
        #expect(changed6)
        let changed7 = book.apply(run(revision: 3, messages: []))
        #expect(!changed7)
        let changed8 = book.apply(run(revision: 4, messages: [message(revision: 4, text: "report")]))
        #expect(!changed8)
        let changed9 = book.apply(run(revision: 5, messages: [message(revision: 5, text: "updated report")]))
        #expect(changed9)
        #expect(book.inserting(into: [question()], summary: nil).last?.plainText.hasSuffix("updated report") == true)
    }

    @Test func unversionedCloudStepUpdatesReplaceContentAtTheSameSequence() {
        var book = HomeAgentMessages()
        let running = run(revision: 0, messages: [message("tell", revision: 0, text: "Please check")])
        let refused = run(revision: 0, messages: [message("tell", revision: 0, text: "Please check\n[Error: outcome: refused]")])
        let changed10 = book.apply(running)
        #expect(changed10)
        let changed11 = book.apply(refused)
        #expect(changed11)
        let changed12 = book.apply(refused)
        #expect(!changed12)
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
        let group = HomeAgentMessageRow.groupID(author: chief, anchor: IdempotencyKey("question"))
        let rows = book.inserting(into: [question(), reply], summary: nil, expanded: [group])
        #expect(rows.map(\.plainText) == ["question", "▾ a1", "[agent_mux → a1]\nplease check", "[a1 → agent_mux]\nchecked", "done"])
    }

    /// User 2026-10-30: Chief's messages to its agents and their reports fold into one row per
    /// answer that names the agents; the full messages show only when that row is expanded.
    @Test func severalAgentMessagesAfterOneAnswerFoldIntoOneRow() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run(revision: 1, messages: [
            .init(id: "tell", sequence: 1, revision: 1, peer: "a1", outgoing: true, text: "please check", date: date),
            .init(id: "tell2", sequence: 2, revision: 1, peer: "a2", outgoing: true, text: "please build", date: date),
            .init(id: "report", sequence: 3, revision: 1, peer: "a1", outgoing: false, text: "checked", date: date),
        ]))
        let rows = book.inserting(into: [question()], summary: nil)
        #expect(rows.count == 2)
        let fold = try #require(rows.last)
        #expect(fold.isReadOnly)
        #expect(fold.plainText.contains("a1") && fold.plainText.contains("a2"))
        #expect(!fold.plainText.contains("please check"))
        #expect(!fold.plainText.contains("checked"))
    }

    @Test func expandedFoldKeepsItsRowFirstAndShowsEveryMessageInOrder() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run(revision: 1, messages: [
            .init(id: "tell", sequence: 1, revision: 1, peer: "a1", outgoing: true, text: "please check", date: date),
            .init(id: "tell2", sequence: 2, revision: 1, peer: "a2", outgoing: true, text: "please build", date: date),
            .init(id: "report", sequence: 3, revision: 1, peer: "a1", outgoing: false, text: "checked", date: date),
        ]))
        let group = HomeAgentMessageRow.groupID(author: chief, anchor: IdempotencyKey("question"))
        let rows = book.inserting(into: [question()], summary: nil, expanded: [group])
        #expect(rows.count == 5)
        #expect(rows[1].agentMessage == HomeAgentMessageRow(group: group, kind: .fold(count: 3, peers: ["a1", "a2"], expanded: true)))
        #expect(rows[2].agentMessage?.kind == .message(from: "agent_mux", to: "a1", outgoing: true, text: "please check"))
        #expect(rows[3].agentMessage?.kind == .message(from: "agent_mux", to: "a2", outgoing: true, text: "please build"))
        #expect(rows[4].agentMessage?.kind == .message(from: "a1", to: "agent_mux", outgoing: false, text: "checked"))
        #expect(rows.dropFirst().allSatisfy { $0.isReadOnly && $0.messageID == nil && $0.agentMessage?.group == group })
        // The fold row keeps its key while it opens and closes, so the view updates it in place.
        let folded = book.inserting(into: [question()], summary: nil)
        #expect(folded[1].key == rows[1].key)
        #expect(folded[1].agentMessage?.kind == .fold(count: 3, peers: ["a1", "a2"], expanded: false))
    }

    @Test func loneAgentMessageShowsAsItselfWithNoFold() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run(revision: 1, messages: [message(revision: 1, text: "checked")]))
        let rows = book.inserting(into: [question()], summary: nil)
        #expect(rows.count == 2)
        let row = try #require(rows.last)
        #expect(row.agentMessage?.kind == .message(from: "a1", to: "agent_mux", outgoing: false, text: "checked"))
    }

    @Test func foldToggleLinkRoundTripsOnlyItsOwnForm() throws {
        let group = HomeAgentMessageRow.groupID(author: chief, anchor: IdempotencyKey("question"))
        #expect(group.count == 16)
        #expect(group == HomeAgentMessageRow.groupID(author: chief, anchor: IdempotencyKey("question")))
        #expect(group != HomeAgentMessageRow.groupID(author: chief, anchor: IdempotencyKey("other")))
        let url = try #require(URL(string: HomeAgentMessageRow.toggleLink(group: group)))
        #expect(HomeAgentMessageRow.group(toggledBy: url) == group)
        for other in ["cmux://agent-messages/xyz", "cmux://agent-messages/\(group)?a=b", "https://agent-messages/\(group)",
                      "cmux://session/\(group)", "cmux://agent-messages/\(group)/x"] {
            #expect(HomeAgentMessageRow.group(toggledBy: try #require(URL(string: other))) == nil)
        }
    }

    @MainActor @Test func toggleOpensAndClosesAFoldInTheStoreTranscript() async {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        let id = ConversationID("conv_aziz")
        #expect(!store.isAgentMessagesExpanded("0123456789abcdef", in: id))
        store.toggleAgentMessages("0123456789abcdef", in: id)
        #expect(store.isAgentMessagesExpanded("0123456789abcdef", in: id))
        store.toggleAgentMessages("0123456789abcdef", in: id)
        #expect(!store.isAgentMessagesExpanded("0123456789abcdef", in: id))
    }

    /// User 2026-10-31: five "stopped without a report" notes and one real report after one answer
    /// were six bubbles behind a link. The real report shows by itself; the notes are one quiet row.
    @Test func statusNotesFoldApartAndARealReportShowsByItself() throws {
        var book = HomeAgentMessages()
        var steps = (1...5).map { index in
            HomeAgentRun.Message(id: "note\(index)", sequence: UInt64(index), revision: 1, peer: "a\(index)", outgoing: false,
                                 text: "(stopped without a report: its session is Disconnected)", date: date)
        }
        steps.append(.init(id: "report", sequence: 6, revision: 1, peer: "a9", outgoing: false, text: "Fixed the feed.", date: date))
        _ = book.apply(run(revision: 1, messages: steps))
        let rows = book.inserting(into: [question()], summary: nil)
        #expect(rows.count == 3)
        #expect(rows.contains { $0.plainText.hasSuffix("Fixed the feed.") })
        #expect(!rows.contains { $0.plainText.contains("stopped without a report") })
    }

    @Test func notesRowNamesItsAgentsAndSharedReasonAndOpensInOrder() throws {
        var book = HomeAgentMessages()
        let notes = (1...3).map { index in
            HomeAgentRun.Message(id: "note\(index)", sequence: UInt64(index), revision: 1, peer: "a\(index)", outgoing: false,
                                 text: "(stopped without a report: its session is Disconnected)", date: date)
        }
        _ = book.apply(run(revision: 1, messages: notes))
        let group = HomeAgentMessageRow.groupID(author: chief, anchor: IdempotencyKey("question"))
        let notesGroup = HomeAgentMessageRow.notesGroup(group)
        #expect(notesGroup != group)
        let folded = book.inserting(into: [question()], summary: nil)
        #expect(folded.count == 2)
        #expect(folded[1].agentMessage == HomeAgentMessageRow(group: notesGroup, kind: .notes(
            count: 3, peers: ["a1", "a2", "a3"], reason: .stopped(session: "Disconnected"), expanded: false)))
        let open = book.inserting(into: [question()], summary: nil, expanded: [notesGroup])
        #expect(open.count == 5)
        #expect(open[1].key == folded[1].key)
        #expect(open.dropFirst(2).map(\.agentMessage?.kind) == (1...3).map {
            HomeAgentMessageRow.Kind?.some(.note(peer: "a\($0)", reason: .stopped(session: "Disconnected"),
                                                 text: "stopped without a report: its session is Disconnected"))
        })
    }

    @Test func oneNoteStillFoldsAndMixedReasonsShareNoReason() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run(revision: 1, messages: [
            .init(id: "n1", sequence: 1, revision: 1, peer: "a1", outgoing: false, text: "(gone: its session no longer exists, so no report will come)", date: date),
            .init(id: "n2", sequence: 2, revision: 1, peer: "a2", outgoing: false, text: "(its report could not be read: bad utf8)", date: date),
        ]))
        let rows = book.inserting(into: [question()], summary: nil)
        guard case let .notes(count, peers, reason, expanded)? = try #require(rows.last).agentMessage?.kind else {
            Issue.record("no notes row"); return
        }
        #expect(count == 2 && peers == ["a1", "a2"] && reason == nil && !expanded)
        var single = HomeAgentMessages()
        _ = single.apply(run(revision: 1, messages: [message(revision: 1, text: "(stopped without a report: its session is Closed)")]))
        let one = single.inserting(into: [question()], summary: nil)
        #expect(one.count == 2)
        #expect(one.last?.agentMessage?.kind == .notes(count: 1, peers: ["a1"], reason: .stopped(session: "Closed"), expanded: false))
    }

    @Test(arguments: [
        ("(stopped without a report: its session is Disconnected)", HomeAgentMessageRow.StatusNote?.some(.stopped(session: "Disconnected"))),
        ("  (gone: its session no longer exists, so no report will come)\n", .some(.gone)),
        ("(its report could not be read: EOF)", .some(.unreadable)),
        ("Fixed the feed (build 41).", nil),
        ("(stopped without a report: its session is Disconnected)\nmore", nil),
        ("(an aside)", nil),
    ])
    func statusNoteReadsOnlyTheProducersThreeForms(text: String, expected: HomeAgentMessageRow.StatusNote?) {
        #expect(HomeAgentMessageRow.statusNote(text) == expected)
    }

    @Test func reportFragmentsWithTheSameTimestampKeepTheirStepSequence() {
        var book = HomeAgentMessages()
        let fragments = (0..<12).reversed().map { index in
            HomeAgentRun.Message(id: "report:a1:\(index)", sequence: UInt64(index + 1), revision: 1,
                                 peer: "a1", outgoing: false, text: "fragment \(index)", date: date)
        }
        _ = book.apply(run(revision: 1, messages: fragments))
        let group = HomeAgentMessageRow.groupID(author: chief, anchor: IdempotencyKey("question"))
        let rows = book.inserting(into: [question()], summary: nil, expanded: [group])
        #expect(rows.dropFirst(2).map(\.plainText) == (0..<12).map { "[a1 → agent_mux]\nfragment \($0)" })
    }

    @Test(arguments: [false, true])
    func nestedQuestionKeepsAgentMessagesInItsBranch(outgoing: Bool) throws {
        var book = HomeAgentMessages()
        var nested = question()
        nested.threadRoot = MessageID("thread")
        nested.replyTo = PartRef(message: MessageID("thread"), partIndex: 0)
        var step = message(revision: 1, text: "Nested assignment")
        step.outgoing = outgoing
        _ = book.apply(run(revision: 1, messages: [step]))
        let rows = book.inserting(into: [question("thread"), nested], summary: nil)
        let projected = try #require(rows.last)
        #expect(projected.isReadOnly)
        #expect(projected.threadRoot == MessageID("thread"))
        #expect(projected.replyTo?.message == MessageID("question"))
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
