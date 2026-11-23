@testable import CmuxNextAgentPane
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// Leo, 2026-11-14: "i also want all our connectivity stuff to shut up and load faster/percievably
/// load faster / whatever it takes / desktop gui, ios, remote, cloud, etc". A machine that dropped
/// said "offline; it will update when it's back" (sidebar tooltip, Settings > Updates) from the
/// first frame, though nothing on screen lets the person act on it and a reconnect heals in seconds.
/// Now the board keeps what it drew before the drop until the drop has lasted the shared connection
/// bound (``QuietHold/connectionDelay``, 10 s); a failure or a machine that cannot update (its
/// Update button) still shows at once. The clock is a ``ManualClock``: no test sleeps.
@MainActor
@Suite struct DaemonUpdateBoardOfflineQuietTests {
    static let id = "acpmux-peer:swarm-10"

    static func event(_ state: DaemonUpdateEvent.State) -> DaemonUpdateEvent {
        DaemonUpdateEvent(id: id, displayName: "swarm-10", sshHost: "swarm-10", state: state)
    }

    /// The board draws the offline line now (tooltip or row).
    static func showsOffline(_ board: DaemonUpdateBoard) -> Bool {
        board.detail(id: id) == DaemonUpdateBoard.line(.offline)
            || board.otherMachines?.lines.contains(DaemonUpdateBoard.offlineLine("swarm-10")) == true
    }

    /// Moves `clock` on by `step` and, when that reached the hold's deadline, lets its show run.
    static func advance(_ clock: ManualClock, by step: Duration, _ board: DaemonUpdateBoard) async {
        let due = clock.sleeperDeadlines.contains { $0 <= clock.now.advanced(by: step) }
        clock.advance(by: step)
        guard due else { return }
        for _ in 0..<10_000 where board.offlineHeld(id) { await Task.yield() }
    }

    /// Applies `event` and, when it started a hold, waits until the hold's timer sleeps on `clock`.
    static func apply(_ event: DaemonUpdateEvent, _ board: DaemonUpdateBoard, _ clock: ManualClock) async throws {
        board.apply(event)
        if board.offlineHeld(id), clock.sleeperCount == 0 { try await clock.waitForSleeper() }
    }

    /// Milliseconds the offline line is on screen over `timeline` (offline at 0, back at `healsAt`,
    /// nil for never) through `until`, stepped in 50 ms slices on one injected clock.
    static func exposureMs(quiet: Duration?, healsAt: Duration?, until end: Duration) async throws -> Int {
        let clock = ManualClock()
        let board = DaemonUpdateBoard(offlineQuiet: quiet, clock: clock)
        try await apply(event(.updated(build: "abc123def")), board, clock)
        try await apply(event(.offline), board, clock)
        let slice = Duration.milliseconds(50)
        var now = Duration.zero
        var visible = 0
        while now < end {
            if let healsAt, now == healsAt { try await apply(event(.updated(build: "abc123def")), board, clock) }
            if showsOffline(board) { visible += 50 }
            await advance(clock, by: slice, board)
            now += slice
        }
        return visible
    }

    @Test func anOfflineMachineSaysNothingUnderTheBoundAndKeepsWhatItDrew() async throws {
        let clock = ManualClock()
        let board = DaemonUpdateBoard(clock: clock)
        try await Self.apply(Self.event(.updated(build: "abc123def")), board, clock)
        let before = board.detail(id: Self.id)
        try await Self.apply(Self.event(.offline), board, clock)
        #expect(board.offlineHeld(Self.id))
        #expect(!Self.showsOffline(board), "an offline line under 10 s")
        #expect(board.detail(id: Self.id) == before, "the board as it was before the drop")
        await Self.advance(clock, by: .milliseconds(9_950), board)
        #expect(!Self.showsOffline(board), "still under the bound at 9.95 s")
        // Said again while the same drop goes on: the wait is not restarted.
        try await Self.apply(Self.event(.offline), board, clock)
        await Self.advance(clock, by: .milliseconds(50), board)
        #expect(Self.showsOffline(board), "at 10 s the line shows")
        #expect(board.otherMachines?.lines == [DaemonUpdateBoard.offlineLine("swarm-10")])
        // Back: the line goes.
        try await Self.apply(Self.event(.cleared), board, clock)
        #expect(!Self.showsOffline(board))
        #expect(board.otherMachines == nil)
    }

    @Test func aMachineBackUnderTheBoundNeverSaysOffline() async throws {
        let clock = ManualClock()
        let board = DaemonUpdateBoard(clock: clock)
        try await Self.apply(Self.event(.offline), board, clock)
        await Self.advance(clock, by: .seconds(6), board)
        try await Self.apply(Self.event(.updated(build: "abc123def")), board, clock)
        #expect(!board.offlineHeld(Self.id))
        await Self.advance(clock, by: .seconds(10), board)
        #expect(!Self.showsOffline(board), "a healed drop never says offline")
        #expect(board.detail(id: Self.id) == DaemonUpdateBoard.line(.updated(build: "abc123def")))
    }

    @Test func theOwnRetriesOfAShownOfflineMachineDoNotHideItAgain() async throws {
        let clock = ManualClock()
        let board = DaemonUpdateBoard(clock: clock)
        try await Self.apply(Self.event(.offline), board, clock)
        await Self.advance(clock, by: .seconds(10), board)
        #expect(Self.showsOffline(board))
        try await Self.apply(Self.event(.updating), board, clock)
        try await Self.apply(Self.event(.offline), board, clock)
        #expect(Self.showsOffline(board), "offline, updating, offline is one drop: shown at once")
    }

    @Test func aFailureOrAnUpdateButtonShowsAtOnce() async throws {
        let clock = ManualClock()
        let board = DaemonUpdateBoard(clock: clock)
        try await Self.apply(Self.event(.offline), board, clock)
        try await Self.apply(Self.event(.failed(reason: "disk full", rolledBack: false)), board, clock)
        #expect(!board.offlineHeld(Self.id))
        #expect(board.otherMachines?.lines == ["Couldn't update swarm-10: disk full"])
        try await Self.apply(Self.event(.offline), board, clock)
        try await Self.apply(Self.event(.cannotUpdate(reason: "Too old to update in place")), board, clock)
        #expect(board.otherMachines?.machines.first?.canUpdate == true, "its Update button shows at once")
    }

    /// The before and after numbers of the PR: offline exposure for a connect healing at 0.8 s, a
    /// reconnect healing at 6 s and a drop lasting 15 s, on one harness.
    @Test func offlineExposureBeforeAndAfter() async throws {
        let end = Duration.seconds(15)
        let timelines: [(name: String, healsAt: Duration?, before: Int, after: Int)] = [
            ("connect heals at 0.8 s", .milliseconds(800), 800, 0),
            ("reconnect heals at 6 s", .seconds(6), 6_000, 0),
            ("drop lasts 15 s", nil, 15_000, 5_000),
        ]
        for timeline in timelines {
            let before = try await Self.exposureMs(quiet: .zero, healsAt: timeline.healsAt, until: end)
            let after = try await Self.exposureMs(quiet: nil, healsAt: timeline.healsAt, until: end)
            print("daemon-update-offline exposure \(timeline.name): before \(before) ms, after \(after) ms")
            #expect(before == timeline.before, "\(timeline.name) before")
            #expect(after == timeline.after, "\(timeline.name) after")
        }
    }
}
