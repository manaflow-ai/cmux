import CmuxNextAgentActivity
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp

/// Leo 2026-10-21 (sidebar organization, item A): every workspace row says what its agent needs
/// in the Priority view's words, needs you, failed or lost, from the same classifier
/// (`AgentPriorityRanking.state`), with the same read marks. Manual order stays as it is. Never
/// Done (Leo 2026-10-21, "WHO BROUGHT BACK THE DONE"): a finished chat's row keeps its unread dot.
@MainActor @Suite(.serialized) struct SidebarRowStatusTests {
    typealias Lanes = SidebarLaneStatusTests

    /// One workspace per chat; `unread` chats finished while nobody looked.
    @MainActor struct Fixture {
        let store = DaemonStore()
        let turns = AgentTurnStateStore()
        let lanes = AgentLaneStore()
        let marks = AgentPriorityMarks(defaults: nil)

        init() throws {
            let chats: [(String, String, Bool)] = [("working", "working", false), ("waiting", "input", false),
                                                   ("failed", "failed", false), ("idle", "idle", false), ("finished", "idle", true)]
            store.apply(snapshot: DaemonTree(workspaces: chats.enumerated().map { index, chat in
                Lanes.workspace(UInt64(index + 1), chat.0, session: "s-\(chat.0)", harness: "claude")
            }))
            turns.localHost = Lanes.host
            for (name, state, unread) in chats {
                lanes.lanes["s-\(name)"] = try #require(AgentActivityLane.of(summary: [
                    "sessionId": "s-\(name)", "name": name, "unread": unread, "lane": ["state": state],
                ]))
            }
        }

        func rows() -> [SidebarWorkspace] {
            SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local),
                                           rowSource: SidebarLaneStatus.applying(nil, lanes: lanes, turns: turns, marks: marks))
                .flatMap(\.workspaces)
        }

        func chips() -> [String: SidebarPriorityEntry.State] {
            Dictionary(uniqueKeysWithValues: rows().compactMap { row in row.agentChip.map { (row.title, $0) } })
        }
    }

    /// Runs `body` with `sidebar.rowStatus` at `on` (nil: its default), then clears it.
    static func withRowStatus(_ on: Bool?, _ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarTunables.rowStatus.key
        TunableStore.shared.set(key, on.map { .bool($0) })
        defer { TunableStore.shared.set(key, nil) }
        try body()
    }

    @Test func rowsNameWhatTheirAgentNeeds() throws {
        let fixture = try Fixture()
        try Self.withRowStatus(true) {
            let chips = fixture.chips()
            #expect(chips == ["waiting": .needsYou, "failed": .failed],
                    "a working, idle or finished chat leaves the row as it was")
        }
    }

    @Test func theChipReadsOnTheNamesLine() throws {
        let fixture = try Fixture()
        try Self.withRowStatus(true) {
            let rows = Dictionary(uniqueKeysWithValues: fixture.rows().map { ($0.title, $0) })
            let options = SidebarLayoutOptions()
            let waiting = options.rowContent(try #require(rows["waiting"]), machine: nil)
            #expect(waiting.chip == .needsYou)
            #expect(options.rowContent(try #require(rows["working"]), machine: nil).chip == nil)
        }
    }

    @Test func markingAChatReadClearsItsRowLikeThePriorityView() throws {
        let fixture = try Fixture()
        try Self.withRowStatus(true) {
            fixture.marks.markRead(try #require(fixture.lanes.lanes["s-failed"]))
            fixture.marks.markRead(try #require(fixture.lanes.lanes["s-finished"]))
            #expect(fixture.chips() == ["waiting": .needsYou])
        }
    }

    /// Off by default (Lawrence 2026-10-21): no chip and no lane state unless the toggles are on.
    @Test func rowsReadNoLanesByDefault() throws {
        let fixture = try Fixture()
        Self.withRowStatus(nil) { #expect(fixture.chips().isEmpty) }
    }

    @Test func theStatusMarkFollowsTheLanes() throws {
        let fixture = try Fixture()
        let key = SidebarTunables.laneStatus.key
        Self.withRowStatus(true) {
            TunableStore.shared.set(key, .bool(true))
            defer { TunableStore.shared.set(key, nil) }
            let activity = Dictionary(uniqueKeysWithValues: fixture.rows().map { ($0.title, $0.activity) })
            #expect(activity["waiting"] == .waiting)
            #expect(activity["failed"] == .error)
            #expect(activity["working"] == .working)
        }
    }

    /// A finished chat drops out before the ranking: it never hides a failed chat in the same
    /// workspace, and its failing checks still read as Red CI.
    @Test func aFinishedChatHidesNothing() throws {
        func lane(_ name: String, _ state: String, unread: Bool) throws -> AgentActivityLane {
            try #require(AgentActivityLane.of(summary: [
                "sessionId": "s-\(name)", "name": name, "unread": unread, "lane": ["state": state],
            ]))
        }
        let finished = try lane("finished", "idle", unread: true), failed = try lane("failed", "failed", unread: false)
        let marks = AgentPriorityMarks(defaults: nil).state
        #expect(SidebarLaneStatus.chip([finished, failed], marks: marks, failingChecks: { _ in false }) == .failed)
        #expect(SidebarLaneStatus.chip([finished], marks: marks, failingChecks: { _ in false }) == nil)
        #expect(SidebarLaneStatus.chip([finished], marks: marks, failingChecks: { _ in true }) == .ciFailing)
    }

    @Test func toggleOffDrawsNoChip() throws {
        let fixture = try Fixture()
        Self.withRowStatus(false) {
            #expect(fixture.chips().isEmpty)
        }
    }

    @Test func manualOrderStaysWhateverTheChips() throws {
        let fixture = try Fixture()
        Self.withRowStatus(true) {
            #expect(fixture.rows().map(\.title) == ["working", "waiting", "failed", "idle", "finished"])
        }
    }
}
