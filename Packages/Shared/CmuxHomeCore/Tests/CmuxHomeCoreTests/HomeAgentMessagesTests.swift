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

    /// The agents row id of the messages after question `anchor` (open it to see them).
    func group(_ anchor: String = "question") -> String {
        HomeAgentMessageRow.groupID(author: chief, anchor: IdempotencyKey(anchor))
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
        let rows = book.inserting(into: [question()], summary: nil, expanded: [group()])
        #expect(rows.count == 3)
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
        let rows = book.inserting(into: [question(), question("other")], summary: nil, expanded: [group("other")])
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
        #expect(book.inserting(into: [question()], summary: nil, expanded: [group()]).last?.plainText.hasSuffix("updated report") == true)
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
        let rows = book.inserting(into: [question()], summary: nil, expanded: [group()])
        #expect(rows.count == 3)
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
        var expectedFold = HomeAgentMessageRow(group: group, kind: .fold(count: 3, peers: ["a1", "a2"], expanded: true))
        // a1's newest message is its report, a2 has only the Chief's message; the newest words are the report.
        expectedFold.peerStates = [.reported, .told]
        expectedFold.latest = "checked"
        // Each agent's title: the first words of the Chief's first message to it.
        expectedFold.peerTitles = ["please check", "please build"]
        // a1's report is unread until the person opens a1 (the agent pane).
        expectedFold.peerUnread = [true, false]
        #expect(rows[1].agentMessage == expectedFold)
        #expect(rows[2].agentMessage?.kind == .message(from: "agent_mux", to: "a1", outgoing: true, text: "please check"))
        #expect(rows[3].agentMessage?.kind == .message(from: "agent_mux", to: "a2", outgoing: true, text: "please build"))
        #expect(rows[4].agentMessage?.kind == .message(from: "a1", to: "agent_mux", outgoing: false, text: "checked"))
        #expect(rows.dropFirst().allSatisfy { $0.isReadOnly && $0.messageID == nil && $0.agentMessage?.group == group })
        // The fold row keeps its key while it opens and closes, so the view updates it in place.
        let folded = book.inserting(into: [question()], summary: nil)
        #expect(folded[1].key == rows[1].key)
        #expect(folded[1].agentMessage?.kind == .fold(count: 3, peers: ["a1", "a2"], expanded: false))
    }

    /// A lone report is a pill too (it was a bubble, before the pills): the agent reported, and its report opens under it.
    @Test func aLoneReportIsAReportedPill() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run(revision: 1, messages: [message(revision: 1, text: "checked")]))
        let rows = book.inserting(into: [question()], summary: nil)
        #expect(rows.count == 2)
        let row = try #require(rows.last?.agentMessage)
        #expect(row.kind == .fold(count: 1, peers: ["a1"], expanded: false))
        #expect(row.peerStates == [.reported] && row.peerTitles == ["a1"] && row.latest == "checked")
        let open = book.inserting(into: [question()], summary: nil, expanded: [group()])
        #expect(open.last?.agentMessage?.kind == .message(from: "a1", to: "agent_mux", outgoing: false, text: "checked"))
    }

    @Test func hundredsOfPeersKeepACompactFallbackAndAllTheirIdentities() throws {
        var book = HomeAgentMessages()
        let messages: [HomeAgentRun.Message] = (0..<300).map { index in
            .init(id: "report:a\(index)", sequence: UInt64(index + 1), revision: 1,
                  peer: "a\(index)", outgoing: false, text: "Report \(index)", date: date)
        }
        _ = book.apply(run(revision: 1, messages: messages))
        let collapsed = book.inserting(into: [question()], summary: nil)
        let fold = try #require(collapsed.last)
        #expect(collapsed.count == 2)
        #expect(fold.plainText == "▸ a0 · a1 · a2 · …")
        #expect(fold.agentMessage?.kind == .fold(count: 300,
               peers: (0..<300).map { "a\($0)" }, expanded: false))
        let group = HomeAgentMessageRow.groupID(author: chief, anchor: IdempotencyKey("question"))
        let expanded = book.inserting(into: [question()], summary: nil, expanded: [group])
        #expect(expanded.count == 302) // question + disclosure + all 300 reports
        #expect(expanded.contains { $0.plainText.hasSuffix("Report 299") })

        // 300 agents that stopped with no report: one agents row, the same short preview.
        var stopped = HomeAgentMessages()
        _ = stopped.apply(run(revision: 1, messages: (0..<300).map { index in
            .init(id: "note:a\(index)", sequence: UInt64(index + 1), revision: 1, peer: "a\(index)", outgoing: false,
                  text: "(stopped without a report: its session is Disconnected)", date: date)
        }))
        let notes = try #require(stopped.inserting(into: [question()], summary: nil).last)
        #expect(notes.plainText == "▸ a0 · a1 · a2 · …")
        guard case let .fold(count, peers, _)? = notes.agentMessage?.kind else {
            Issue.record("expected the agents row"); return
        }
        #expect(count == 300 && peers.count == 300)
        #expect(notes.agentMessage?.peerStates.allSatisfy { $0 == .stopped } == true)
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
    /// were six bubbles behind a link. Since the pills (2026-11-03) they are one agents row: five stopped
    /// pills and one reported pill, and opening it shows each note and the report in order.
    @Test func statusNotesAndAReportAreOneAgentsRow() throws {
        var book = HomeAgentMessages()
        var steps = (1...5).map { index in
            HomeAgentRun.Message(id: "note\(index)", sequence: UInt64(index), revision: 1, peer: "a\(index)", outgoing: false,
                                 text: "(stopped without a report: its session is Disconnected)", date: date)
        }
        steps.append(.init(id: "report", sequence: 6, revision: 1, peer: "a9", outgoing: false, text: "Fixed the feed.", date: date))
        _ = book.apply(run(revision: 1, messages: steps))
        let rows = book.inserting(into: [question()], summary: nil)
        #expect(rows.count == 2)
        let pills = try #require(rows.last?.agentMessage)
        #expect(pills.kind == .fold(count: 6, peers: ["a1", "a2", "a3", "a4", "a5", "a9"], expanded: false))
        #expect(pills.peerStates == Array(repeating: .stopped, count: 5) + [.reported])
        #expect(!rows.contains { $0.plainText.contains("stopped without a report") })
        let open = book.inserting(into: [question()], summary: nil, expanded: [group()])
        #expect(open.count == 8 && open[1].key == rows[1].key)
        #expect(open.dropFirst(2).prefix(5).map(\.agentMessage?.kind) == (1...5).map {
            HomeAgentMessageRow.Kind?.some(.note(peer: "a\($0)", reason: .stopped(session: "Disconnected"),
                                                 text: "stopped without a report: its session is Disconnected"))
        })
        #expect(open.last?.plainText.hasSuffix("Fixed the feed.") == true)
    }

    /// An agent the Chief told and that then stopped is one stopped pill, not a working one and a stopped one.
    @Test func aToldAgentThatStoppedIsOneStoppedPill() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run(revision: 1, messages: [
            .init(id: "tell", sequence: 1, revision: 1, peer: "a1", outgoing: true, text: "please check", date: date),
            .init(id: "n1", sequence: 2, revision: 1, peer: "a1", outgoing: false, text: "(gone: its session no longer exists, so no report will come)", date: date),
            .init(id: "n2", sequence: 3, revision: 1, peer: "a2", outgoing: false, text: "(its report could not be read: bad utf8)", date: date),
        ]))
        let row = try #require(book.inserting(into: [question()], summary: nil).last?.agentMessage)
        #expect(row.kind == .fold(count: 3, peers: ["a1", "a2"], expanded: false))
        #expect(row.peerStates == [.stopped, .stopped] && row.peerTitles == ["please check", "a2"])
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

    /// User 2026-11-03 (msg 19960): every agent the Chief spawns or talks to is one pill in one row per
    /// answer: its newest step sets its state (a status note stops it), and its title is the Chief's task title.
    @Test func everyAgentOfAnAnswerIsOnePillWithItsNewestStateAndTitle() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run(revision: 1, messages: [
            .init(id: "tell", sequence: 1, revision: 1, peer: "a1", outgoing: true, text: "Title: Fix the sidebar\n\nAlign it.", date: date),
            .init(id: "tell2", sequence: 2, revision: 1, peer: "a2", outgoing: true, text: "please build the nightly", date: date),
            .init(id: "tell3", sequence: 3, revision: 1, peer: "a3", outgoing: true, text: "audit the buttons", date: date),
            .init(id: "report", sequence: 4, revision: 1, peer: "a1", outgoing: false, text: "Fixed.", date: date),
            .init(id: "note", sequence: 5, revision: 1, peer: "a2", outgoing: false,
                  text: "(stopped without a report: its session is Disconnected)", date: date),
        ]))
        let rows = book.inserting(into: [question()], summary: nil)
        #expect(rows.count == 2)
        let pills = try #require(rows.last?.agentMessage)
        #expect(pills.kind == .fold(count: 5, peers: ["a1", "a2", "a3"], expanded: false))
        #expect(pills.peerStates == [.reported, .stopped, .told])
        #expect(pills.peerTitles == ["Fix the sidebar", "please build the nightly", "audit the buttons"])
        // Opened, the row stays first and every message and note follows in order.
        let open = book.inserting(into: [question()], summary: nil, expanded: [pills.group])
        #expect(open.count == 7 && open[1].key == rows[1].key)
    }

    /// A lone task is a pill too (it was a bubble): the agent is working on it.
    @Test func aLoneTaskIsAPill() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run(revision: 1, messages: [
            .init(id: "tell", sequence: 1, revision: 1, peer: "a1", outgoing: true, text: "Title: Nightly rebuild\n\nGo.", date: date),
        ]))
        let row = try #require(book.inserting(into: [question()], summary: nil).last?.agentMessage)
        #expect(row.kind == .fold(count: 1, peers: ["a1"], expanded: false))
        #expect(row.peerStates == [.told] && row.peerTitles == ["Nightly rebuild"])
    }

    /// A pill's title (user 2026-11-03): the task's `Title:` line, else its first clause cut at a word edge to
    /// about 32 characters with no trailing punctuation, never a fixed five words cut mid-phrase.
    @Test(arguments: [
        ("Add auto-archive: off by default, 3 days idle, in the Tidy Up dialog and Settings.", "Add auto-archive"),
        ("Title: Fix caret blink\n\nUser msg 1: the caret blinks.", "Fix caret blink"),
        ("Buttons respond first click: test every button with one click", "Buttons respond first click"),
        ("Default picked: reserve one Mac mini's nightly slot", "Default picked"),
        ("Hold the push until the nightly appcast builds - then land it", "Hold the push until the nightly"),
        ("Check Text Size in the docs. Then fix the sidebar.", "Check Text Size in the docs"),
        ("Rebuild the appcast; then push", "Rebuild the appcast"),
        ("Audit every button for first-click response\nin both windows", "Audit every button for"),
        ("**Please** check the `nightly` build and report back today", "Please check the nightly build"),
        ("Fix the v1.2 release notes", "Fix the v1.2 release notes"),
        ("Supercalifragilisticexpialidociousnessly long word", "Supercalifragilisticexpialidociousnessly"),
        // A quoted message's speaker header is no title (user 2026-11-04, msg 21664: "User (Nov 4)").
        ("User (Nov 4): \"are we cancelling nightlies? we need to just make nightlies build\"", "are we cancelling nightlies"),
        ("User: why is the computer overloaded", "why is the computer overloaded"),
    ])
    func aTitleIsTheTitleLineElseTheFirstClauseAtAWordEdge(text: String, expected: String) {
        #expect(HomeAgentMessageRow.title(of: text) == expected)
    }

    /// A pill names an agent by its task's `Title:` line (the spawn task's first line), else the
    /// first words of the Chief's first message (user 2026-11-03, msg 19960: the ChatGPT-style pills).
    @Test func anAgentsTitleIsItsTasksTitleLineElseItsFirstWords() {
        #expect(HomeAgentMessageRow.title(of: "Title: Fix caret blink\n\nUser msg 1: the caret blinks.") == "Fix caret blink")
        #expect(HomeAgentMessageRow.title(of: "**Please** check the `nightly` build and report back today") == "Please check the nightly build")
        #expect(HomeAgentMessageRow.title(of: "\n\n") == nil)
    }

    /// User 2026-11-04 (msg 21664): an agent's pill and chat are named by its spawn task's `Title:` line, in every
    /// row it shows in, never by a later tell's first clause ("User (Nov 4)").
    @Test func anAgentKeepsItsSpawnTitleInLaterRows() throws {
        var book = HomeAgentMessages()
        let spawn = HomeAgentRun(conversation: conversation, id: "run-spawn", author: chief, turn: nil,
                                 answers: [MessageID("question")], threadRoot: nil, revision: 1, messages: [
            .init(id: "spawn:a988", sequence: 1, revision: 1, peer: "a988", outgoing: true,
                  text: "Title: Bubble tail last only\n\nOnly the last bubble of a run gets the tail.", date: date),
        ])
        let tell = HomeAgentRun(conversation: conversation, id: "run-tell", author: chief, turn: nil,
                                answers: [MessageID("later")], threadRoot: nil, revision: 1, messages: [
            .init(id: "tell:1", sequence: 1, revision: 1, peer: "a988", outgoing: true,
                  text: "User (Nov 4): \"are we cancelling nightlies?\"", date: date.addingTimeInterval(60)),
        ])
        _ = book.apply(spawn)
        _ = book.apply(tell)
        let rows = book.inserting(into: [question(), question("later")], summary: nil)
        let folds = rows.compactMap(\.agentMessage).filter { if case .fold = $0.kind { true } else { false } }
        #expect(folds.count == 2)
        #expect(folds.map(\.peerTitles) == [["Bubble tail last only"], ["Bubble tail last only"]])
        let thread = try #require(book.thread(peer: "a988", in: rows))
        #expect(thread.title == "Bubble tail last only")
        #expect(thread.task?.hasPrefix("Title: Bubble tail last only") == true)
    }

    /// The Chief's own post of the turn that started `peer`: a `send` (key `send-<conversation>-<turn>-<16 hex>`).
    func chiefSend(_ turn: String, hash: String = "000000000000000a", thread: String? = nil) -> TranscriptItem {
        .init(key: IdempotencyKey("send-\(conversation.rawValue)-\(turn)-\(hash)"), seq: 2, author: chief,
              parts: [.text("Started a1002 on Cmd+P memory.")], createdAt: date.addingTimeInterval(5), delivery: .committed,
              replyTo: thread.map { PartRef(message: MessageID($0), partIndex: 0) }, threadRoot: thread.map { MessageID($0) },
              messageID: MessageID("send-\(hash)"))
    }

    func spawnRun(turn: String) -> HomeAgentRun {
        HomeAgentRun(conversation: conversation, id: "run-\(turn)", author: chief, turn: IdempotencyKey(turn),
                     answers: [MessageID("question")], threadRoot: nil, revision: 1, messages: [
            .init(id: "spawn:a1002", sequence: 1, revision: 1, peer: "a1002", outgoing: true,
                  text: "Title: Cmd+P search memory\n\nUser (Nov 5): the whole raw task.", date: date.addingTimeInterval(1)),
        ])
    }

    /// User 2026-11-05 (msg 22013): a spawn turn's pills show beside the Chief's words of that turn, not alone
    /// under the person's message while the words went into its thread.
    @Test func spawnPillsFollowTheChiefsTextOfTheirTurn() throws {
        var book = HomeAgentMessages()
        _ = book.apply(spawnRun(turn: "turn-7"))
        let rows = book.inserting(into: [question(), chiefSend("turn-7", thread: "question")], summary: nil)
        #expect(rows.count == 3)
        #expect(rows[1].key.rawValue.hasPrefix("send-"))
        let fold = try #require(rows.last)
        #expect(fold.agentMessage?.peerTitles == ["Cmd+P search memory"])
        #expect(fold.threadRoot == MessageID("question"))
        #expect(fold.replyTo?.message == MessageID("question"))
    }

    /// A send of another turn is no anchor: the pills stay under the message they answer.
    @Test func anotherTurnsSendIsNoAnchor() {
        var book = HomeAgentMessages()
        _ = book.apply(spawnRun(turn: "turn-7"))
        let rows = book.inserting(into: [question(), chiefSend("turn-70")], summary: nil)
        #expect(rows.count == 3)
        #expect(rows[1].agentMessage != nil)
        #expect(rows[1].threadRoot == nil)
    }

    /// Of several sends in the turn, the one on the main line (no thread) carries the pills.
    @Test func aMainLineSendWinsOverAThreadedOne() {
        var book = HomeAgentMessages()
        _ = book.apply(spawnRun(turn: "turn-7"))
        let rows = book.inserting(into: [question(), chiefSend("turn-7", hash: "000000000000000a", thread: "question"),
                                         chiefSend("turn-7", hash: "000000000000000b")], summary: nil)
        #expect(rows.count == 4)
        #expect(rows[3].agentMessage != nil)
        #expect(rows[3].threadRoot == nil)
    }
}
