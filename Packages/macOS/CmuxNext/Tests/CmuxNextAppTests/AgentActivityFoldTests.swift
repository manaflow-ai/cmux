import CmuxNextHistory
import Foundation
import Testing

/// A hook report that changes no durable state gets no journal row, so during a long turn the
/// daemon writes one coalesced row for the whole session at most each 5 minutes with the report
/// times of the terminals that reported (`native_event` `AgentActivityObserved`, the times in
/// `normalized.activity`). The fold moves the last activity of the sessions it knows and nothing
/// else. The twin of `cmux-history/tests/agent_activity.rs`.
@Suite struct AgentActivityFoldTests {
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    static func fold() -> AgentSessionFold {
        var fold = AgentSessionFold(machine: "local")
        fold.apply([
            AgentJournalRecord(sequence: 1, kind: "agent.session.started", occurredAtMs: 1_000, subjects: [], provider: "claude", sessionID: "long"),
            AgentJournalRecord(sequence: 2, kind: "agent.turn.started", occurredAtMs: 2_000, subjects: [], provider: "claude", sessionID: "long"),
            AgentJournalRecord(sequence: 3, kind: "agent.session.started", occurredAtMs: 1_000, subjects: [], provider: "claude", sessionID: "done"),
            AgentJournalRecord(sequence: 4, kind: "agent.session.ended", occurredAtMs: 3_000, subjects: [], provider: "claude", sessionID: "done"),
        ])
        return fold
    }

    @Test func anActivityRowMovesOnlyTheLastActivityOfKnownSessions() throws {
        var fold = Self.fold()
        fold.apply([AgentJournalRecord(sequence: 5, activity: [
            (provider: "claude", sessionID: "long", atMs: 600_000),
            // An older time never moves a session back.
            (provider: "claude", sessionID: "done", atMs: 2_500),
            // A stamp of a session the fold never saw makes no session.
            (provider: "claude", sessionID: "unknown", atMs: 600_000),
            // The same id of another provider is another session.
            (provider: "codex", sessionID: "long", atMs: 900_000),
        ])])
        #expect(fold.cursor == 5)
        #expect(fold.ordered.map(\.sessionID) == ["long", "done"])
        let long = try #require(fold.ordered.first { $0.sessionID == "long" })
        #expect(long.lastActivityAt == Self.date(600_000))
        #expect(long.startedAt == Self.date(1_000))
        #expect(long.endedAt == nil)
        let done = try #require(fold.ordered.first { $0.sessionID == "done" })
        #expect(done.lastActivityAt == Self.date(3_000))
        #expect(done.endedAt == Self.date(3_000))
    }

    /// The row as the daemon's journal read sends it.
    @Test func theWireRowDecodes() throws {
        let wire = """
        {"sequence":"5","kind":"agent.state.changed","occurred_at_ms":"9000000","subjects":[],
         "payload":{"format":"cmux.agent-hook.v1","adapter":{"id":"cmux","version":1},
          "native_event":"AgentActivityObserved","native":{},
          "normalized":{"observed_at_ms":"9000000","activity":[
            {"adapter":"claude","agent_session_id":"long","terminal":"t-1","observed_at_ms":"600000"}]}}}
        """
        var fold = Self.fold()
        fold.apply([try JSONDecoder().decode(AgentJournalRecord.self, from: Data(wire.utf8))])
        let long = try #require(fold.ordered.first { $0.sessionID == "long" })
        #expect(long.lastActivityAt == Self.date(600_000))
        #expect(fold.ordered.count == 2)
    }
}
