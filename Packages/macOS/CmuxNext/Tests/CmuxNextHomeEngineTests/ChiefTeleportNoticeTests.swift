@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The Teleport chip, menu and the Chief conversation's row read the same marks of the home's
/// `state` folder: `moved.json` (where and when), `moving.json` (a move that runs now, from any
/// entry point) and `fork.json` (its fork in cmux Cloud).
struct ChiefTeleportNoticeTests {
    private static let moved = Data(#"{"to": "cloud:https://api.cmux.dev/agent_9", "at": "2026-11-06T16:02:11Z", "checkpoint_sha256": "ab"}"#.utf8)
    private static let moving = Data(#"{"pid": 4242, "at": "2026-11-06T16:01:00Z", "to": "cloud"}"#.utf8)
    private static let fork = Data(#"{"api": "https://api.cmux.dev", "chief": "agent_fork", "conversation": "conv_1", "name": "Chief fork", "at": "2026-11-06T15:30:00Z", "memory_messages": 23376, "history_imported": 1000}"#.utf8)
    private static let utc = TimeZone(identifier: "UTC")!

    private func notice(_ announcement: ChiefTeleportAnnouncement?, _ phase: ChiefTeleportPhase = .idle) -> String? {
        ChiefTeleportNotice(phase: phase, announcement: announcement, placeName: { ChiefTeleportChip.placeTitle($0, current: nil) }).text(timeZone: Self.utc)
    }

    @Test func theMarksReadWhereWhenAndARunningMoveAndTheFork() throws {
        let marks = ChiefHomeMarks(movedJSON: Self.moved, movingJSON: Self.moving, forkJSON: Self.fork, isRunning: { $0 == 4242 })
        #expect(marks.whereabouts == ChiefWhereabouts(location: .cloud, cloudAgentID: "agent_9"))
        #expect(marks.movedAt == Date(timeIntervalSince1970: 1_793_980_931))
        #expect(marks.moving == ChiefMoveHold(pid: 4242, to: .cloud))
        #expect(marks.fork == ChiefForkRecord(name: "Chief fork", chief: "agent_fork", at: Date(chiefRFC3339: "2026-11-06T15:30:00Z")))
        // A hold whose mover is gone is a move that died: nothing runs.
        #expect(ChiefHomeMarks(movedJSON: nil, movingJSON: Self.moving, forkJSON: nil, isRunning: { _ in false }).moving == nil)
        // The hold of an engine that writes no target still says a move runs.
        #expect(ChiefHomeMarks(movedJSON: nil, movingJSON: Data(#"{"pid": 7}"#.utf8), forkJSON: nil, isRunning: { _ in true }).moving == ChiefMoveHold(pid: 7, to: nil))
        #expect(ChiefHomeMarks(movedJSON: nil, movingJSON: Data("{}".utf8), forkJSON: Data("no".utf8), isRunning: { _ in true }) == .none)
    }

    @Test func theEventIsTheChangeBetweenTwoReads() throws {
        let moved = ChiefHomeMarks(movedJSON: Self.moved, movingJSON: nil, forkJSON: nil, isRunning: { _ in false })
        let forked = ChiefHomeMarks(movedJSON: nil, movingJSON: nil, forkJSON: Self.fork, isRunning: { _ in false })
        #expect(ChiefTeleportAnnouncement(from: .none, to: moved) == .moved(.cloud, at: moved.movedAt))
        #expect(ChiefTeleportAnnouncement(from: moved, to: .none) == .movedBack)
        #expect(ChiefTeleportAnnouncement(from: .none, to: forked) == .forked("Chief fork", at: forked.fork?.at))
        #expect(ChiefTeleportAnnouncement(from: forked, to: forked) == nil, "the same fork read again is not news")
        #expect(ChiefTeleportAnnouncement(from: moved, to: moved) == nil)
    }

    @Test func theRowSaysWhereTheChiefWentAndWhen() throws {
        let at = try #require(Date(chiefRFC3339: "2026-11-06T16:02:11Z"))
        let time = ChiefTeleportNotice.time(at, Self.utc)
        #expect(notice(.moved(.cloud, at: at)) == "Chief moved to cmux Cloud · \(time)")
        #expect(notice(.moved(.cloud, at: at), .done("cmux Cloud")) == "Chief moved to cmux Cloud · \(time)")
        #expect(notice(nil) == nil, "no event, no row")
    }

    @Test func theRowShowsARunningMoveAFailureAndARollback() {
        #expect(notice(nil, .moving("cmux Cloud")) == "Chief is moving to cmux Cloud…")
        #expect(notice(nil, .verifying("Mac mini")) == "Chief is moving to Mac mini…")
        #expect(notice(nil, .failed("cmux Cloud", reason: "the cloud did not answer\nsteps: …")) == "Chief did not move to cmux Cloud: the cloud did not answer")
        #expect(notice(nil, .rollingBack) == "Chief is moving back to this Mac…")
        #expect(notice(.movedBack, .rolledBack) == "Chief moved back to this Mac")
        #expect(notice(nil, .rolledBack) == nil, "an old rollback is not news")
    }

    @Test func theRowNamesTheForkWhileThisMacAnswers() throws {
        let at = try #require(Date(chiefRFC3339: "2026-11-06T15:30:00Z"))
        let time = ChiefTeleportNotice.time(at, Self.utc)
        #expect(notice(.forked("Chief fork", at: at)) == "Chief forked to cmux Cloud as “Chief fork” · \(time)")
    }

    @Test func todayReadsAsATimeAndAnotherDayWithItsDate() throws {
        let at = try #require(Date(chiefRFC3339: "2026-11-06T16:02:11Z"))
        let today = ChiefTeleportNotice.time(at, Self.utc, now: at.addingTimeInterval(60))
        let later = ChiefTeleportNotice.time(at, Self.utc, now: at.addingTimeInterval(3 * 86_400))
        #expect(!today.contains("2026"))
        #expect(later.contains("2026") || later.contains("Nov"))
        #expect(later.hasSuffix(today))
    }

    /// A move from the CLI, the MCP tool or the Chief itself writes the hold; the app's chip, menu
    /// and row show it running with no move started from the app.
    @MainActor @Test func aMoveTheHoldSaysRunsShowsAsMovingInTheChipMenuAndRow() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("chief-teleport-notice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("state"), withIntermediateDirectories: true)
        try Self.moving.write(to: home.appendingPathComponent("state/moving.json"))
        try Self.fork.write(to: home.appendingPathComponent("state/fork.json"))
        let model = ChiefTeleportModel(home: home, reader: ChiefLocationReader(isRunning: { $0 == 4242 }))
        model.destinations = { [.init(id: "local", title: "This Mac", place: .thisMac), .init(id: "cloud", title: "cmux Cloud", place: .cloud)] }
        await model.refresh().value
        #expect(model.phase == .idle)
        #expect(model.shownPhase == .moving("cmux Cloud"))
        #expect(model.notice() == "Chief is moving to cmux Cloud…")
        #expect(model.menu().rows.map(\.state) == [.current, .busy], "no second move starts while one runs")
        let menu = ChiefTeleportMenuBuilder(model: model).makeMenu()
        #expect(menu.items.map(\.title).contains("Moving to cmux Cloud…"))
        #expect(menu.items.map(\.title).contains("Fork in cmux Cloud: Chief fork"))
        // The move ends: the engine removes the hold, the fork stays. The fork was there at the first
        // read, so it is no event: no row, while the menu still names it.
        try FileManager.default.removeItem(at: home.appendingPathComponent("state/moving.json"))
        await model.refresh().value
        #expect(model.shownPhase == .idle)
        #expect(model.notice() == nil)
        #expect(model.menu().rows.map(\.state) == [.current, .available])
    }
}
