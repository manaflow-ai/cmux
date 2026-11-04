import Foundation
import Testing
@testable import CmuxHomeCore

/// The agent pane's data (user 2026-11-03, msg 19960): one agent's chat with the Chief from the run rows
/// (its task, later messages, how long it worked, the Chief's link to its workspace), and the pills' unread
/// dot, which clears once the person opens the agent and comes back with a newer report.
struct HomeAgentThreadTests {
    let chief = ParticipantID("agent_mux")
    let start = Date(timeIntervalSince1970: 1_000)

    func step(_ id: String, _ seq: UInt64, _ peer: String, out: Bool, _ text: String, at seconds: Double) -> HomeAgentRun.Message {
        .init(id: id, sequence: seq, revision: 1, peer: peer, outgoing: out, text: text, date: start.addingTimeInterval(seconds))
    }

    func run(_ messages: [HomeAgentRun.Message], id: String = "run", answers: [MessageID] = [MessageID("question")]) -> HomeAgentRun {
        .init(conversation: ConversationID("c"), id: id, author: chief, turn: nil, answers: answers, revision: 1, messages: messages)
    }

    func item(_ id: String, author: ParticipantID, _ text: String) -> TranscriptItem {
        .init(key: IdempotencyKey(id), seq: 1, author: author, parts: [.text(text)], createdAt: start, delivery: .committed,
              messageID: MessageID(id))
    }

    @Test func anAgentsThreadIsItsTaskThenEveryLaterMessageAcrossRuns() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run([
            step("tell", 1, "a1", out: true, "Title: Fix the sidebar\n\nAlign the header.", at: 0),
            step("tell2", 2, "a2", out: true, "build the nightly", at: 1),
            step("report", 3, "a1", out: false, "Root cause found.", at: 120),
        ]))
        _ = book.apply(run([
            step("tell3", 1, "a1", out: true, "Also add a test.", at: 200),
            step("report2", 2, "a1", out: false, "Done: landed.", at: 335),
        ], id: "run2"))
        let items = [item("question", author: ParticipantID("me"), "fix it"),
                     item("reply", author: chief, "Started [a1](cmux://chief/0123abcd/session/s-81) and [a2](https://example.com).")]
        let thread = try #require(book.thread(peer: "a1", in: items))
        #expect(thread.title == "Fix the sidebar")
        #expect(thread.task == "Title: Fix the sidebar\n\nAlign the header.")
        #expect(thread.entries.map(\.text) == ["Root cause found.", "Also add a test.", "Done: landed."])
        #expect(thread.entries.map(\.outgoing) == [false, true, false])
        #expect(thread.state == .reported)
        #expect(thread.workedFor(now: start.addingTimeInterval(9_999)) == 335)
        #expect(thread.newestReportAt == start.addingTimeInterval(335))
        #expect(thread.workspaceLink == URL(string: "cmux://chief/0123abcd/session/s-81"))
        // a2 is still working: its time runs to now, and the Chief's only link for it is no session link.
        let working = try #require(book.thread(peer: "a2", in: items))
        #expect(working.state == .told && working.endedAt == nil && working.newestReportAt == nil)
        #expect(working.workedFor(now: start.addingTimeInterval(61)) == 60)
        #expect(working.workspaceLink == nil)
        #expect(book.thread(peer: "a9", in: items) == nil)
    }

    @Test func aStoppedAgentsThreadEndsWithItsNote() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run([
            step("tell", 1, "a1", out: true, "check the feed", at: 0),
            step("note", 2, "a1", out: false, "(stopped without a report: its session is Disconnected)", at: 72),
        ]))
        let thread = try #require(book.thread(peer: "a1", in: []))
        #expect(thread.state == .stopped && thread.workedFor(now: .distantFuture) == 72)
    }

    @Test(arguments: [
        ("[a1](cmux://chief/0123abcd/session/s-1)", "cmux://chief/0123abcd/session/s-1"),
        ("[a1](cmux://chief/0123ABCD/session/s-1)", nil),
        ("[a1](cmux://chief/0123abcd/session/s 1)", nil),
        ("[a12](cmux://chief/0123abcd/session/s-1)", nil),
        ("[a1](cmux://session/s-1)", nil),
        ("[a1](cmux://chief/0123abcd/session/old) then [a1](cmux://chief/0123abcd/session/new)", "cmux://chief/0123abcd/session/new"),
    ] as [(String, String?)])
    func theWorkspaceLinkIsOnlyTheChiefsSessionLinkForThatAgent(text: String, expected: String?) {
        #expect(HomeAgentThread.workspaceLink(for: "a1", in: [text]) == expected.flatMap(URL.init(string:)))
    }

    @Test func aReportedPillIsUnreadUntilSeenAndAgainAfterANewerReport() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run([
            step("tell", 1, "a1", out: true, "check", at: 0),
            step("tell2", 2, "a2", out: true, "build", at: 1),
            step("report", 3, "a1", out: false, "checked", at: 50),
        ]))
        let question = item("question", author: ParticipantID("me"), "go")
        func unread(_ seen: [String: Date]) -> [Bool]? {
            book.inserting(into: [question], summary: nil, seen: seen).last?.agentMessage?.peerUnread
        }
        #expect(unread([:]) == [true, false])
        #expect(unread(["a1": start.addingTimeInterval(50)]) == [false, false])
        _ = book.apply(run([step("report2", 4, "a1", out: false, "checked again", at: 90)]))
        #expect(unread(["a1": start.addingTimeInterval(50)]) == [true, false])
    }
}
