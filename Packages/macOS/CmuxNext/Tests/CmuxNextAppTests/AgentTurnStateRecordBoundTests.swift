import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Observation
import Testing

/// The app's turn-state records (`AgentTurnStateStore`) are bounded (design sweep 2026-11-18, item
/// 18): a read never makes a record, a chat acpmux deletes or stops listing loses its record, and
/// past the cap the idle records written longest ago go. Before, every read of an unknown id made
/// an empty record and nothing ever removed one, so the store only grew over the app's days.
@MainActor
struct AgentTurnStateRecordBoundTests {
    static let host = "install:record-bound"

    private nonisolated final class Woke: @unchecked Sendable { var value = false }

    static func store() -> AgentTurnStateStore {
        let turns = AgentTurnStateStore()
        turns.localHost = host
        return turns
    }

    static func ref(_ session: String) -> AgentSessionRef { AgentSessionRef(host: host, session: session) }

    static func message(_ json: String) throws -> AgentTurnStateFeed.Message {
        try #require(AgentTurnStateFeed.Message(line: Data(json.utf8)))
    }

    @Test func readingUnknownIdsLeavesTheStoreEmpty() {
        let turns = Self.store()
        for index in 0..<500 {
            let ref = Self.ref("unknown-\(index)")
            #expect(turns.state(for: ref) == nil)
            #expect(turns.title(for: ref) == nil)
            #expect(turns.detail(for: ref) == nil)
            #expect(turns.isMuted(ref) == nil)
            #expect(turns.lastMessage(for: ref) == nil)
            #expect(!turns.isWorking(ref, isChatMachine: { _ in true }))
        }
        #expect(turns.recordCount == 0, "reads made \(turns.recordCount) records")
    }

    /// A reader of a session with no record yet still redraws when the watch first writes it.
    @Test func aReaderOfAnUnknownIdRedrawsWhenTheWatchWritesIt() {
        let turns = Self.store()
        let changed = Woke()
        withObservationTracking { _ = turns.title(for: Self.ref("later")) } onChange: { changed.value = true }
        turns.apply(session: "later", state: .working, lastMessage: nil, muted: false, title: "Later", detail: nil)
        #expect(changed.value,"the reader was not told the session appeared")
        #expect(turns.title(for: Self.ref("later")) == "Later")
    }

    /// A reader of a session with no record hears that session's first write only: another session getting its record
    /// (a subagent starting, another machine's chat) does not wake it. Every record-less chat row of the sidebar heard
    /// every new record before (Leo's NIGHTLY 2026-11-21: 18 % of the main thread mapping rows again).
    @Test func aReaderOfAnUnknownIdSleepsThroughOtherIdsFirstWrites() {
        let turns = Self.store()
        let changed = Woke()
        withObservationTracking {
            _ = turns.title(for: Self.ref("gone"))
            _ = turns.state(for: Self.ref("gone"))
            _ = turns.lastMessage(for: Self.ref("gone"))
        } onChange: { changed.value = true }
        for index in 0..<50 {
            turns.apply(session: "other-\(index)", state: .working, lastMessage: nil, muted: false, title: nil, detail: nil)
        }
        #expect(!changed.value, "a reader of a record-less session woke on other sessions' first writes")
        turns.apply(session: "gone", state: .working, lastMessage: nil, muted: false, title: "Back", detail: nil)
        #expect(changed.value, "the reader was not told its own session appeared")
    }

    @Test func aDeletedSessionLosesItsRecord() throws {
        let turns = Self.store()
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/record-bound.sock", turns: turns, lanes: AgentLaneStore())
        feed.handle(try Self.message(#"{"method":"_acpmux/session_changed","params":{"sessionId":"s1","session":{"sessionId":"s1","indicator":"working","title":"Fix it"}}}"#))
        #expect(turns.recordCount == 1)
        let redrew = Woke()
        withObservationTracking { _ = turns.title(for: Self.ref("s1")) } onChange: { redrew.value = true }
        feed.handle(try Self.message(#"{"method":"_acpmux/session_changed","params":{"sessionId":"s1","kind":"purged"}}"#))
        #expect(turns.recordCount == 0, "a deleted chat kept its record")
        #expect(redrew.value,"a tab showing the deleted chat was not told")
        #expect(turns.title(for: Self.ref("s1")) == nil)
        #expect(turns.state(for: Self.ref("s1")) == nil)
    }

    /// A peer's purge drops only that peer's row; the record goes with its last row.
    @Test func aPeerPurgeDropsTheRecordWithItsLastRow() throws {
        let turns = Self.store()
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/record-bound-peer.sock", turns: turns, lanes: AgentLaneStore())
        feed.handle(try Self.message(#"{"method":"_acpmux/session_changed","params":{"sessionId":"p1","peer":"lab","session":{"sessionId":"p1","indicator":"working","peer":"lab"}}}"#))
        #expect(turns.recordCount == 1)
        feed.handle(try Self.message(#"{"method":"_acpmux/session_changed","params":{"sessionId":"p1","kind":"purged","peer":"lab"}}"#))
        #expect(turns.recordCount == 0, "a purged peer row left an empty record")
    }

    @Test func aSessionTheWholeListNoLongerHasLosesItsRecord() {
        let turns = Self.store()
        var states = AgentTurnStates()
        states.set("a", .working)
        states.set("b", .done)
        turns.replace(states: states, lastMessages: [:], muted: [], titles: ["a": "A", "b": "B"], details: [:])
        #expect(turns.recordCount == 2)
        var later = AgentTurnStates()
        later.set("a", .working)
        turns.replace(states: later, lastMessages: [:], muted: [], titles: ["a": "A"], details: [:], keeping: [])
        #expect(turns.recordCount == 1, "a session gone from the list kept its record")
        #expect(turns.title(for: Self.ref("b")) == nil)
        #expect(turns.title(for: Self.ref("a")) == "A")
    }

    /// A push newer than the page (`keeping`) is not undone by the page.
    @Test func aKeptSessionStaysThoughThePageLacksIt() {
        let turns = Self.store()
        turns.apply(session: "pushed", state: .working, lastMessage: nil, muted: false, title: "Pushed", detail: nil)
        turns.replace(states: AgentTurnStates(), lastMessages: [:], muted: [], titles: [:], details: [:], keeping: ["pushed"])
        #expect(turns.title(for: Self.ref("pushed")) == "Pushed")
    }

    /// The watch closing keeps titles (a tab reads as its chat while it reconnects).
    @Test func theWatchClosingKeepsTheRecords() {
        let turns = Self.store()
        turns.apply(session: "a", state: .working, lastMessage: nil, muted: false, title: "A", detail: nil)
        turns.clearLive()
        #expect(turns.recordCount == 1)
        #expect(turns.title(for: Self.ref("a")) == "A")
    }

    /// Past the cap the idle records written longest ago go; a working one stays.
    @Test func pastTheCapTheOldestIdleRecordsGo() {
        let turns = Self.store()
        turns.recordCap = 80
        turns.apply(session: "busy", state: .working, lastMessage: nil, muted: false, title: "Busy", detail: nil)
        for index in 0..<400 {
            turns.apply(session: "idle-\(index)", state: nil, lastMessage: nil, muted: false, title: "Idle \(index)", detail: nil)
        }
        #expect(turns.recordCount <= 80, "the store held \(turns.recordCount) records past a cap of 80")
        #expect(turns.title(for: Self.ref("busy")) == "Busy", "a working chat lost its record to the cap")
        #expect(turns.title(for: Self.ref("idle-399")) == "Idle 399", "the newest record went")
        #expect(turns.title(for: Self.ref("idle-0")) == nil, "the oldest idle record stayed")
    }
}
