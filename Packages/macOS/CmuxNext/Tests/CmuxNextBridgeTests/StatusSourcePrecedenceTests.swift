import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextBridge
@testable import CmuxNextDaemon

/// Status sources (cx-kxa2): an explicit report (OSC 7501 from the program,
/// an agent hook) wins over the screen detector (the herdr-derived agent
/// plugin, roster source `plugin` or legacy `detected`); a detector report
/// never hides a fresher explicit one. An agent chat whose last turn ended
/// while nobody watched (acpmux `unread`) shows done until it is opened.
@MainActor
struct StatusSourcePrecedenceTests {
    static func record(_ state: String, updatedAtMs: UInt64, seq: UInt64 = 1) throws -> ProgramStatusRecord {
        try #require(ProgramStatusRecord(.object([
            "id": .string(""), "state": .string(state), "updated_seq": .string(String(seq)),
            "updated_at_ms": .string(String(updatedAtMs)),
        ])))
    }

    static func tab() throws -> TabModel {
        let store = try BridgeFixture.store()
        return try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first)
    }

    @Test func aProgramRecordDecodesItsReportTime() throws {
        #expect(try Self.record("done", updatedAtMs: 1_700_000_000_123).updatedAtMs == 1_700_000_000_123)
    }

    @Test func aDetectorReportYieldsToAFresherProgramRecord() throws {
        let tab = try Self.tab()
        tab.setAgent(AgentStatus(surface: 1, state: .working, source: "plugin", agent: "claude", updatedAtMs: 100))
        tab.programStatus = [try Self.record("done", updatedAtMs: 200)]
        let summary = StatusMapping(seen: ProgramStatusSeenStore()).summary(tab)
        #expect(summary.state == .success)
        #expect(!summary.reports.contains { $0.source == .agent })
        // The legacy `detected` source is a detector too.
        tab.setAgent(AgentStatus(surface: 1, state: .blocked, source: "detected", agent: "claude", updatedAtMs: 150))
        #expect(StatusMapping(seen: ProgramStatusSeenStore()).summary(tab).state == .success)
    }

    @Test func aFresherDetectorReportStillShows() throws {
        let tab = try Self.tab()
        tab.programStatus = [try Self.record("done", updatedAtMs: 100)]
        tab.setAgent(AgentStatus(surface: 1, state: .working, source: "plugin", agent: "claude", updatedAtMs: 300))
        let summary = StatusMapping(seen: ProgramStatusSeenStore()).summary(tab)
        #expect(summary.state == .working)
        #expect(summary.reports.contains { $0.source == .agent })
    }

    @Test func aHookReportIsExplicitAndStays() throws {
        let tab = try Self.tab()
        tab.setAgent(AgentStatus(surface: 1, state: .blocked, source: "hook", agent: "claude", updatedAtMs: 100))
        tab.programStatus = [try Self.record("working", updatedAtMs: 200)]
        let summary = StatusMapping(seen: ProgramStatusSeenStore()).summary(tab)
        #expect(summary.state == .waiting)
        #expect(summary.reports.contains { $0.source == .agent })
    }

    static func chat() throws -> TabModel { try AgentTurnIndicatorTests.chat() }

    static func turns(_ summary: [String: Any]) -> AgentTurnStateStore {
        let store = AgentTurnStateStore()
        store.localHost = "install:mac-1"
        store.states.reset(["sessions": [summary]])
        return store
    }

    @Test func aChatTurnThatEndedUnwatchedIsDoneUntilOpened() throws {
        let unread: [String: Any] = ["sessionId": "s-1", "status": "ready", "pendingPermissions": 0, "unread": true,
                                     "lastTurn": ["turnId": "t-1", "status": "completed"]]
        let done = StatusMapping(turns: Self.turns(unread)).summary(try Self.chat())
        #expect(done.state == .success)
        var read = unread
        read["unread"] = false
        #expect(StatusMapping(turns: Self.turns(read)).summary(try Self.chat()) == .idle)
        // A cancelled turn is not an outcome to show.
        var cancelled = unread
        cancelled["lastTurn"] = ["turnId": "t-1", "status": "cancelled"]
        #expect(StatusMapping(turns: Self.turns(cancelled)).summary(try Self.chat()) == .idle)
    }
}
