import AppKit
@testable import CmuxNextApp
import CmuxNextHistory
import CmuxNextHistoryDaemon
import Foundation
import Testing

/// Journal retention deletes the records of an old agent session. The daemon still lists that session whole
/// (`history-agent-sessions-v1`: the agent rows of `history.entries.list` carry the terminal, the tab, the
/// start and the end), and the vault, the agents palette and resume by id read `AgentHistory.sessions`. These
/// check that a session comes out of the daemon's rows as the app's own journal fold had it, with no journal
/// record of it.
@MainActor @Suite(.serialized) struct AgentHistoryListTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    /// The reply of `history.entries.list {kinds:[agent]}`: an idle session that still runs, and one that ended.
    static func rows(now: Date) throws -> [DaemonHistoryEntry] {
        let ms = { (seconds: TimeInterval) in String(Int64(now.addingTimeInterval(seconds).timeIntervalSince1970 * 1_000)) }
        let reply = """
            {"entries":[
              {"id":"agent:local/claude/s-idle","kind":"agent","at_ms":"\(ms(-7_200))","title":"Claude Code","available":true,
               "running":true,"session_id":"s-idle","provider":"claude","cwd":"/work/project","workspace":"workspace_1",
               "terminal":"terminal_1","tab":"tab_1","started_at_ms":"\(ms(-86_400))"},
              {"id":"agent:local/codex/s-ended","kind":"agent","at_ms":"\(ms(-3_600))","title":"Codex","available":true,
               "running":false,"session_id":"s-ended","provider":"codex","terminal":"terminal_2","tab":"tab_2",
               "started_at_ms":"\(ms(-10_800))","ended_at_ms":"\(ms(-3_600))"}
            ],"revision":"7"}
            """
        return try JSONDecoder().decode(DaemonHistoryList.self, from: Data(reply.utf8)).entries
    }

    @Test func aListedSessionIsTheWholeSessionWithNoJournalRecord() throws {
        let now = Date()
        let services = Self.services()
        let listed = try Self.rows(now: now).compactMap { $0.agentSession(machine: "local") }
        services.history.agents.machines["local"] = MachineAgentSessions(machine: "local", listed: listed)

        // Newest activity first: the vault and the agents palette show this order.
        #expect(services.history.agents.sessions.map(\.sessionID) == ["s-ended", "s-idle"])
        // Resume by id finds the idle session, with the tab and terminal that `HistoryRestorer` and the vault's
        // live check read.
        let idle = try #require(services.history.agents.session(id: "s-idle"))
        #expect(idle.qualifiedID == "local/claude/s-idle")
        #expect(idle.tab == "tab_1")
        #expect(idle.terminal == "terminal_1")
        #expect(idle.workspace == "workspace_1")
        #expect(idle.cwd == "/work/project")
        #expect(idle.endedAt == nil)
        #expect(abs(idle.startedAt.timeIntervalSince(now.addingTimeInterval(-86_400))) < 1)
        #expect(abs(idle.lastActivityAt.timeIntervalSince(now.addingTimeInterval(-7_200))) < 1)
        let ended = try #require(services.history.agents.session(id: "local/codex/s-ended"))
        #expect(ended.tab == "tab_2")
        let endedAt = try #require(ended.endedAt)
        #expect(abs(endedAt.timeIntervalSince(now.addingTimeInterval(-3_600))) < 1)
    }

    /// The daemon's list replaces a journal fold the app made of the same daemon's older build: a session the
    /// fold had and the list does not have is gone, and a listed one is not there two times.
    @Test func theListReplacesAnOlderJournalFold() throws {
        let now = Date()
        let services = Self.services()
        var fold = AgentSessionFold(machine: "local")
        let at = Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        fold.apply([AgentJournalRecord(sequence: 1, kind: "agent.session.started", occurredAtMs: at, subjects: [], provider: "claude", sessionID: "s-idle"),
                    AgentJournalRecord(sequence: 2, kind: "agent.session.started", occurredAtMs: at, subjects: [], provider: "amp", sessionID: "s-folded")])
        var machine = MachineAgentSessions(fold: fold)
        #expect(Set(machine.sessions.map(\.sessionID)) == ["s-idle", "s-folded"])

        let listed = try Self.rows(now: now).compactMap { $0.agentSession(machine: "local") }
        machine.take(listed: listed)
        services.history.agents.machines["local"] = machine
        #expect(services.history.agents.sessions.map(\.sessionID) == ["s-ended", "s-idle"])
        #expect(machine.fold.cursor == 0)
    }

    /// A row of a daemon without `history-agent-sessions-v1` has only its last activity time.
    @Test func aRowOfAnOlderDaemonKeepsItsOldMeaning() throws {
        let row = try JSONDecoder().decode(DaemonHistoryEntry.self, from: Data("""
            {"id":"agent:local/claude/s-old","kind":"agent","at_ms":"5000","title":"Claude Code","available":true,
             "running":false,"session_id":"s-old","provider":"claude"}
            """.utf8))
        let session = try #require(row.agentSession(machine: "remote-1"))
        #expect(session.machine == "remote-1")
        #expect(session.tab == nil)
        #expect(session.startedAt == Date(timeIntervalSince1970: 5))
        #expect(session.endedAt == Date(timeIntervalSince1970: 5))
        guard case .agent(let payload)? = row.historyEntry(untitled: "")?.payload else { Issue.record("not an agent row"); return }
        #expect(payload.machine == "local")
        #expect(payload.sessionID == "s-old")
    }
}
