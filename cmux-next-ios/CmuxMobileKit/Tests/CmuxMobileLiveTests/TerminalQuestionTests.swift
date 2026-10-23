import CmuxAgentQuestion
import CmuxMobileFeed
@testable import CmuxMobileLive
import Foundation
import Testing

/// A terminal agent's question (the daemon's `question` on its notification,
/// cmux-tui `agent_hook_question.rs`): parsed like an acpmux question, answered
/// by typing into Claude Code's AskUserQuestion screen (verified live against
/// Claude Code 2.1.308, `verify/push-matrix.md` "Terminal agent questions").
@Suite struct TerminalQuestionTests {
    nonisolated(unsafe) static let claude: [String: Any] = [
        "harness": "claude", "tool_use_id": "toolu_1",
        "questions": [
            ["question": "Which branch?", "header": "Branch", "multiSelect": false,
             "options": [["label": "main", "description": "the default"], ["label": "dev"], ["label": "release"]]],
            ["question": "Which checks?", "header": "Checks", "multiSelect": true,
             "options": [["label": "lint"], ["label": "tests"], ["label": "docs"]]],
        ],
    ]

    static func question(_ json: [String: Any] = claude) -> AgentQuestion {
        AgentQuestion(terminalQuestion: json, ledgerID: "ntf_9", surface: 7)!
    }

    static func answer(_ question: AgentQuestion, _ picks: [[String]], other: [String?] = []) -> AgentQuestionAnswer {
        var selections: [String: AgentQuestionAnswer.Selection] = [:]
        for (i, item) in question.items.enumerated() {
            let ids = item.options.filter { (i < picks.count ? picks[i] : []).contains($0.label) }.map(\.id)
            selections[item.id] = .init(optionIDs: ids, other: i < other.count ? other[i] : nil)
        }
        return AgentQuestionAnswer(selections: selections)
    }

    static func text(_ steps: [Data]) -> [String] { steps.map { String(decoding: $0, as: UTF8.self) } }

    @Test func parsesLikeAnAcpmuxQuestion() {
        let q = Self.question()
        #expect(q.id == "ntf_9")
        #expect(q.source.harness == .claude)
        #expect(q.source.session == "s7")
        #expect(q.items.count == 2)
        #expect(q.items[0].options.map(\.label) == ["main", "dev", "release"])
        #expect(q.items[0].options[0].detail == "the default")
        #expect(q.items[1].multiSelect)
        #expect(q.items[0].allowsOther)
        #expect(AgentQuestion(terminalQuestion: ["questions": []], ledgerID: "x", surface: 1) == nil)
        let codex = AgentQuestion(terminalQuestion: ["harness": "codex", "questions": [
            ["id": "d", "question": "Deploy?", "isOther": false, "options": [["label": "yes"], ["label": "no"]]],
        ]], ledgerID: "n", surface: 2)
        #expect(codex?.source.harness == .codex)
    }

    /// One single-choice question: its number answers it (no review screen).
    @Test func oneSingleChoiceIsItsNumber() throws {
        let q = Self.question(["harness": "claude", "questions": [
            ["question": "Pick a color?", "multiSelect": false, "options": [["label": "red"], ["label": "green"], ["label": "blue"]]],
        ]])
        #expect(Self.text(try TerminalQuestionKeys.claude(q, Self.answer(q, [["green"]]))) == ["2"])
        // Other: its row's number, the text, Return.
        #expect(Self.text(try TerminalQuestionKeys.claude(q, Self.answer(q, [[]], other: ["teal please"])))
            == ["4", "teal please", "\r"])
    }

    /// Several questions: a number per single choice (it moves on), a number per
    /// pick of a multi-select, Tab to move on, then 1 on the review screen.
    @Test func severalQuestionsEndOnTheReview() throws {
        let q = Self.question()
        #expect(Self.text(try TerminalQuestionKeys.claude(q, Self.answer(q, [["dev"], ["lint", "docs"]])))
            == ["2", "1", "3", "\t", "1"])
    }

    /// A multi-select with Other: its row's number checks it, Down to it, the text,
    /// Down to Submit, Return; the review screen follows.
    @Test func multiSelectWithOther() throws {
        let q = Self.question(["harness": "claude", "questions": [
            ["question": "Which fruits?", "multiSelect": true, "options": [["label": "apple"], ["label": "pear"], ["label": "plum"]]],
        ]])
        let down = "\u{1b}[B"
        #expect(Self.text(try TerminalQuestionKeys.claude(q, Self.answer(q, [["pear"]], other: ["kiwi"])))
            == ["2", "4", down + down + down, "kiwi", down, "\r", "1"])
    }

    @Test func refusesWhatTheScreenCannotTake() {
        let q = Self.question()
        // Unanswered question.
        #expect(throws: TerminalQuestionKeys.Refusal.self) { try TerminalQuestionKeys.claude(q, Self.answer(q, [["dev"], []])) }
        // A control character in Other could press keys the person never chose.
        let one = Self.question(["harness": "claude", "questions": [["question": "Q?", "options": [["label": "a"]]]]])
        #expect(throws: TerminalQuestionKeys.Refusal.self) {
            try TerminalQuestionKeys.claude(one, Self.answer(one, [[]], other: ["ok\u{1b}[A\r"]))
        }
        // Codex's screen is not mapped yet.
        let codex = AgentQuestion(terminalQuestion: ["harness": "codex", "questions": [
            ["id": "d", "question": "Deploy?", "options": [["label": "yes"]]],
        ]], ledgerID: "n", surface: 2)!
        #expect(throws: TerminalQuestionKeys.Refusal.self) { try TerminalQuestionKeys.keys(codex, Self.answer(codex, [["yes"]])) }
    }

    /// Keys go only while the terminal shows this very question with the chosen labels.
    @Test func screenCheck() {
        let q = Self.question()
        let a = Self.answer(q, [["dev"], ["lint"]])
        let screen = """
        ←  ☐ Branch  ☐ Checks  ✔ Submit  →
        Which branch?
        ❯ 1. main
             the default
          2. dev
          3. release
          4. Type something.
        """
        #expect(TerminalQuestionKeys.screenShows(screen, question: q, answer: a))
        // Another question on screen, or a label that moved: nothing is typed.
        #expect(!TerminalQuestionKeys.screenShows(screen.replacingOccurrences(of: "Which branch?", with: "Which tag?"), question: q, answer: a))
        #expect(!TerminalQuestionKeys.screenShows(screen.replacingOccurrences(of: "2. dev", with: "2. staging"), question: q, answer: a))
        #expect(!TerminalQuestionKeys.screenShows("$ ", question: q, answer: a))
    }
}

/// The Feed card of a terminal agent's question: the question and its options
/// inline, answered by keys typed into that terminal only while it shows it.
@MainActor
@Suite struct TerminalQuestionFeedTests {
    nonisolated static let question = #"{"harness":"claude","tool_use_id":"toolu_1","questions":[{"question":"Which branch?","header":"Branch","multiSelect":false,"options":[{"label":"main","description":"the default"},{"label":"dev"},{"label":"release"}]}]}"#

    static func row(question: String? = TerminalQuestionFeedTests.question) -> String {
        let extra = question.map { #","question":\#($0)"# } ?? ""
        return #"{"id":"ntf_9","title":"Claude asked a question","subtitle":null,"body":"AskUserQuestion","level":"warning","terminal_id":"term_x","surface":1,"created_at_ms":5000000,"source":"agent","acknowledged":false\#(extra)}"#
    }

    nonisolated static let screen = "Which branch?\n❯ 1. main\n     the default\n  2. dev\n  3. release\n  4. Type something."

    final class Daemon {
        var rows: [String] = []
        var screen: String
        init() { screen = TerminalQuestionFeedTests.screen }
        var typed: [(Int, String)] = []
        var reads = 0

        func respond(_ command: String, _ params: [String: Int]) -> Data {
            switch command {
            case "list-notifications":
                return Data(#"{"ok":true,"data":{"notifications":[\#(rows.joined(separator: ","))]}}"#.utf8)
            case "read-screen":
                reads += 1
                let text = String(data: try! JSONSerialization.data(withJSONObject: [screen]), encoding: .utf8)!.dropFirst().dropLast()
                return Data(#"{"ok":true,"data":{"text":\#(text)}}"#.utf8)
            default:
                return Data(#"{"ok":true,"data":{}}"#.utf8)
            }
        }
    }

    static func make(_ daemon: Daemon) -> (FeedStore, TerminalFeed) {
        let (store, feed) = TerminalFeedTests.make(TerminalFeedTests.FakeDaemon())
        feed.request = { command, params, _ in daemon.respond(command, params) }
        feed.type = { surface, bytes, _ in daemon.typed.append((surface, String(decoding: bytes, as: UTF8.self))) }
        feed.keyPause = .zero
        return (store, feed)
    }

    @Test func theQuestionShowsInlineWithItsOptions() async {
        let daemon = Daemon()
        daemon.rows = [Self.row()]
        let (store, feed) = Self.make(daemon)
        feed.treeChanged(TerminalFeedTests.tree(), macID: "mac", connection: TerminalFeedTests.connection)
        await TerminalFeedTests.settle { store.items.count == 1 }
        let item = store.item(id: "term-mac-ntf_9")
        guard case .question(let question) = item?.kind else {
            Issue.record("not a question card: \(String(describing: item?.kind))")
            return
        }
        #expect(question.items.first?.prompt == "Which branch?")
        #expect(question.items.first?.options.map(\.label) == ["main", "dev", "release"])
        #expect(item?.opensTerminal == true)
        #expect(item?.needsYou == true)
        #expect(item?.markdown == "Which branch?")
        // The agent moved on (the row no longer carries the question): answered in the terminal.
        daemon.rows = [Self.row(question: nil)]
        await feed.refresh()
        #expect(store.item(id: "term-mac-ntf_9")?.resolution == "Answered in the terminal")
        #expect(store.item(id: "term-mac-ntf_9")?.needsYou == false)
        // A row without the question from the start (an older Mac) is a needs-input card.
        let (older, olderFeed) = Self.make(daemon)
        olderFeed.treeChanged(TerminalFeedTests.tree(), macID: "mac", connection: TerminalFeedTests.connection)
        await TerminalFeedTests.settle { older.items.count == 1 }
        #expect(older.item(id: "term-mac-ntf_9")?.kind == .needsInput)
    }

    @Test func anAnswerTypesItsKeysWhileTheTerminalShowsTheQuestion() async throws {
        let daemon = Daemon()
        daemon.rows = [Self.row()]
        let (store, feed) = Self.make(daemon)
        feed.treeChanged(TerminalFeedTests.tree(), macID: "mac", connection: TerminalFeedTests.connection)
        await TerminalFeedTests.settle { store.items.count == 1 }
        guard let item = store.item(id: "term-mac-ntf_9"), case .question(let question) = item.kind else {
            Issue.record("no question card")
            return
        }
        let answer = TerminalQuestionTests.answer(question, [["dev"]])
        try await feed.answer(item, question: question, with: answer)
        #expect(daemon.reads == 1)
        #expect(daemon.typed.map(\.0) == [1])
        #expect(daemon.typed.map(\.1) == ["2"])
        // Another question on screen: nothing is typed, and the card says why.
        daemon.typed = []
        daemon.screen = "$ "
        await #expect(throws: TerminalFeed.QuestionRefused.self) { try await feed.answer(item, question: question, with: answer) }
        #expect(daemon.typed.isEmpty)
        // Decline is Escape, also only on the question's screen.
        daemon.screen = Self.screen
        try await feed.decline(item, question: question)
        #expect(daemon.typed.map(\.1) == ["\u{1b}"])
    }

    /// The push's question (kind `question`, `tabId` `s1`) finds the same card.
    @Test func aPushFindsTheTerminalsPendingQuestion() async {
        let daemon = Daemon()
        daemon.rows = [Self.row()]
        let (store, feed) = Self.make(daemon)
        feed.treeChanged(TerminalFeedTests.tree(), macID: "mac", connection: TerminalFeedTests.connection)
        await TerminalFeedTests.settle { store.items.count == 1 }
        #expect(feed.pendingQuestion(tabID: "s1", eventID: "q-c2e23c8e74d254a9")?.0.id == "term-mac-ntf_9")
        #expect(feed.pendingQuestion(tabID: "s2", eventID: "q-c2e23c8e74d254a9") == nil)
    }

    /// A notification answers only the question it was sent for (review B1): an old
    /// notification (Notification Center, or a Retry) for question A never types into a
    /// newer question B on the same tab, even when their options share labels. A push
    /// that names no question (an older Mac) does not answer from the notification.
    @Test func aPushAnswersOnlyItsOwnQuestion() async {
        let daemon = Daemon()
        daemon.rows = [Self.row()]
        let (store, feed) = Self.make(daemon)
        feed.treeChanged(TerminalFeedTests.tree(), macID: "mac", connection: TerminalFeedTests.connection)
        await TerminalFeedTests.settle { store.items.count == 1 }
        // The Mac's vector (notify_terminal tests): the same key from the same question.
        #expect(TerminalFeed.Entry.eventID(question: ["questions": [["question": "Which branch?",
            "options": [["label": "main"], ["label": "dev"], ["label": "release"]]]]]) == "q-c2e23c8e74d254a9")
        #expect(feed.pendingQuestion(tabID: "s1", eventID: "q-0000000000000001") == nil)
        #expect(feed.pendingQuestion(tabID: "s1", eventID: "n-4") == nil)
        #expect(feed.pendingQuestion(tabID: "s1", eventID: nil) == nil)
    }
}
