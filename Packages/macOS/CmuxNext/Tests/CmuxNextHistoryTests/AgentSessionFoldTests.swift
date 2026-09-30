import CmuxNextHistory
import Foundation
import Testing

struct AgentSessionFoldTests {
    static func record(_ sequence: UInt64, _ kind: String, session: String?, provider: String = "claude",
                       ms: Int64, cwd: String? = nil, subjects: [AgentJournalRecord.Subject] = []) -> AgentJournalRecord {
        AgentJournalRecord(sequence: sequence, kind: kind, occurredAtMs: ms, subjects: subjects, provider: provider,
                           sessionID: session, cwd: cwd)
    }

    @Test func startTurnsAndEndMakeOneSession() throws {
        var fold = AgentSessionFold(machine: "home")
        fold.apply([
            Self.record(1, "agent.session.started", session: "s1", ms: 1_000, cwd: "/repo",
                        subjects: [.init("terminal", "term_1"), .init("tab", "tab_1"), .init("workspace", "ws_1")]),
            Self.record(2, "agent.turn.completed", session: "s1", ms: 5_000),
            Self.record(3, "agent.session.ended", session: "s1", ms: 9_000),
        ])
        let session = try #require(fold.ordered.first)
        #expect(fold.sessions.count == 1)
        #expect(session.cwd == "/repo" && session.terminal == "term_1" && session.tab == "tab_1" && session.workspace == "ws_1")
        #expect(session.startedAt == Date(timeIntervalSince1970: 1))
        #expect(session.lastActivityAt == Date(timeIntervalSince1970: 9))
        #expect(session.endedAt == Date(timeIntervalSince1970: 9))
        #expect(fold.cursor == 3)
    }

    @Test func reReadingOldRecordsDoesNotDoubleCount() {
        var fold = AgentSessionFold(machine: "home")
        let records = [Self.record(1, "agent.session.started", session: "s1", ms: 1_000),
                       Self.record(2, "agent.session.ended", session: "s1", ms: 2_000)]
        fold.apply(records)
        fold.apply(records + [Self.record(3, "agent.session.started", session: "s1", ms: 3_000)])
        #expect(fold.sessions.count == 1)
        // Resumed with the same id: running again.
        #expect(fold.ordered.first?.endedAt == nil)
        #expect(fold.cursor == 3)
    }

    @Test func activityWithoutAStartStillMakesASession() {
        var fold = AgentSessionFold(machine: "box")
        fold.apply([Self.record(7, "agent.turn.started", session: "x", provider: "codex", ms: 4_000)])
        #expect(fold.ordered.first?.provider == "codex")
        #expect(fold.ordered.first?.machine == "box")
    }

    @Test func recordsWithoutASessionIDAreIgnored() {
        var fold = AgentSessionFold(machine: "home")
        fold.apply([Self.record(1, "agent.state.changed", session: nil, ms: 1)])
        #expect(fold.sessions.isEmpty)
        #expect(fold.cursor == 1)
    }

    @Test func capacityKeepsTheMostRecentlyActive() {
        var fold = AgentSessionFold(machine: "home", capacity: 2)
        fold.apply((1...4).map { Self.record(UInt64($0), "agent.session.started", session: "s\($0)", ms: Int64($0) * 1000) })
        #expect(fold.ordered.map(\.sessionID) == ["s4", "s3"])
    }

    @Test func decodesTheJournalEnvelope() throws {
        let json = """
        {"sequence":"42","kind":"agent.session.started","occurred_at_ms":1785715200000,"class":"state",
         "subjects":[{"kind":"terminal","id":"term_9"},{"kind":"workspace","id":"ws_2"}],
         "payload":{"format":"x","adapter":{"id":"codex","version":1},"native_event":"SessionStart",
           "normalized":{"agent_session_id":"abc","cwd":"/tmp/p","observed_at_ms":"1785715201000"},"native":{}}}
        """
        let record = try JSONDecoder().decode(AgentJournalRecord.self, from: Data(json.utf8))
        var fold = AgentSessionFold(machine: "home")
        fold.apply([record])
        let session = try #require(fold.ordered.first)
        #expect(record.sequence == 42)
        #expect(session.provider == "codex" && session.sessionID == "abc" && session.cwd == "/tmp/p")
        #expect(session.startedAt == Date(timeIntervalSince1970: 1_785_715_201))
    }

    /// The live daemon sends `sequence` and `occurred_at_ms` as decimal
    /// strings (resource API v2); a record with a string time was dropped.
    @Test func decodesStringTimesFromTheLiveDaemon() throws {
        let json = """
        {"sequence":"30","kind":"agent.session.started","occurred_at_ms":"1790810388279","committed_at_ms":"1790810388279",
         "subjects":[{"kind":"session","id":"session_x"}],
         "payload":{"adapter":{"id":"claude","version":1},"normalized":{"agent_session_id":"hist-test-1"}}}
        """
        let record = try JSONDecoder().decode(AgentJournalRecord.self, from: Data(json.utf8))
        #expect(record.occurredAtMs == 1_790_810_388_279)
    }

    @Test func resumeCommandsQuoteUnsafeIDs() {
        #expect(AgentResume.command(provider: "claude", sessionID: "0b1c-22") == "claude --resume 0b1c-22")
        #expect(AgentResume.command(provider: "codex", sessionID: "a b'c") == "codex resume 'a b'\\''c'")
        #expect(AgentResume.command(provider: "unknown", sessionID: "x") == nil)
    }
}
