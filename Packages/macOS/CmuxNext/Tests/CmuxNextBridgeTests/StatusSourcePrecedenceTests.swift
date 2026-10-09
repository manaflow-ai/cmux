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

    /// A chat's completed turn is done until the user looks at the chat, like
    /// an OSC 7501 done: client seen state keyed by session and turn, because
    /// an open chat tab stays attached to acpmux in a background workspace,
    /// so acpmux `unread` alone never marks it (live run 1008-203749-42312f).
    @Test func aCompletedChatTurnIsDoneUntilSeen() throws {
        func summary(turn: String, status: String = "completed") -> [String: Any] {
            ["sessionId": "s-1", "status": "ready", "pendingPermissions": 0, "unread": false,
             "lastTurn": ["turnId": turn, "status": status]]
        }
        let seen = ProgramStatusSeenStore()
        let tab = try Self.chat()
        #expect(StatusMapping(turns: Self.turns(summary(turn: "t-1")), seen: seen).summary(tab).state == .success)
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").status == .none, "shared stores know nothing")
        seen.markTurnSeen(session: "s-1", turn: "t-1")
        #expect(StatusMapping(turns: Self.turns(summary(turn: "t-1")), seen: seen).summary(tab) == .idle)
        // The next completed turn is new: done again.
        #expect(StatusMapping(turns: Self.turns(summary(turn: "t-2")), seen: seen).summary(tab).state == .success)
        // A cancelled turn is not an outcome to show.
        #expect(StatusMapping(turns: Self.turns(summary(turn: "t-3", status: "cancelled")), seen: seen).summary(tab) == .idle)
    }

    /// Looking at a chat tab sees its completed turn.
    @Test func lookingAtAChatSeesItsTurn() throws {
        let turns = Self.turns(["sessionId": "s-1", "status": "ready", "pendingPermissions": 0,
                                "lastTurn": ["turnId": "t-9", "status": "completed"]])
        let seen = ProgramStatusSeenStore()
        let tab = try Self.chat()
        seen.markSeen(tab, turns: turns)
        #expect(seen.isTurnSeen(session: "s-1", turn: "t-9"))
        #expect(StatusMapping(turns: turns, seen: seen).summary(tab) == .idle)
    }

    /// At (re)connect, chats whose last turn completed while a client watched
    /// them (acpmux `unread` false) start seen, so old chats do not all light
    /// up; one that ended unwatched stays done until opened.
    @Test func reconnectSeedsOnlyWatchedTurnsAsSeen() {
        let result: [String: Any] = ["sessions": [
            ["sessionId": "watched", "status": "ready", "unread": false, "lastTurn": ["turnId": "t-1", "status": "completed"]],
            ["sessionId": "unwatched", "status": "ready", "unread": true, "lastTurn": ["turnId": "t-2", "status": "completed"]],
            ["sessionId": "busy", "status": "running", "lastTurn": ["turnId": "t-3", "status": "completed"]],
        ]]
        #expect(AgentTurnStates.settledTurns(result).map { "\($0.session)/\($0.turn)" } == ["watched/t-1"])
    }
}
