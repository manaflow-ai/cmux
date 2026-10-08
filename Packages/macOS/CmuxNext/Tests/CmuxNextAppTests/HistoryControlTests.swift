@testable import CmuxNextApp
import CmuxNextHistory
import CmuxNextSettings
import Foundation
import Testing

/// `history.list` params and entry JSON (plans/cmux-next/history.md 5.3).
struct HistoryControlTests {
    @Test func parsesKindRangeTextAndLimit() throws {
        let query = try HistoryControl.query(from: ["kind": .string("agent"), "range": .string("week"), "text": .string("api"),
                                                    "limit": .number(20)])
        #expect(query.kinds == [.agent] && query.range == .week && query.text == "api" && query.limit == 20)
        #expect(try HistoryControl.query(from: ["kind": .string("all")]).kinds.isEmpty)
        #expect(throws: (any Error).self) { try HistoryControl.query(from: ["kind": .string("bogus")]) }
        #expect(throws: (any Error).self) { try HistoryControl.query(from: ["range": .string("year")]) }
    }

    @Test func agentEntriesCarryTheResumeCommand() {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let session = AgentSession(machine: "local", provider: "claude", sessionID: "abc-1", cwd: "/repo",
                                   startedAt: time, lastActivityAt: time)
        let entry = HistoryEntry(id: "agent:local/claude/abc-1", kind: .agent, time: time, title: "Claude Code in repo",
                                 payload: .agent(session))
        let json = HistoryControl.json(entry)
        #expect(json["resume_command"]?.stringValue == "claude --resume abc-1")
        #expect(json["running"]?.boolValue == true)
        #expect(json["kind"]?.stringValue == "agent")
    }
}
