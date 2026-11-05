@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextWakeupsTestSupport
import Testing

/// T-KEYS (frame-owner-s4): a key resize or a divider drag changes a terminal's fit grid on almost every display
/// frame, and each report resized the PTY and sent SIGWINCH. ``TerminalGridReportCoalescer`` applies Ghostty.app's
/// rule (`src/termio/Thread.zig`, `min_ms = 25`): one resize per 25 ms window, always the newest grid. Every test
/// runs on a manual clock: the window is a `DemandTimer` deadline, so nothing here waits on the wall clock.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalGridReportCoalescerTests {
    /// One 120 Hz display frame, rounded down to the nanosecond.
    static let frame: Duration = .nanoseconds(8_333_333)

    @MainActor final class Sent {
        var grids: [TerminalGridSize] = []
        var times: [Duration] = []
    }

    struct Rig {
        let clock: ManualClock
        let sent: Sent
        let coalescer: TerminalGridReportCoalescer

        @MainActor init() {
            let clock = ManualClock()
            let sent = Sent()
            self.clock = clock
            self.sent = sent
            coalescer = TerminalGridReportCoalescer(clock: clock) { grid in
                sent.grids.append(grid)
                sent.times.append(clock.now.offset)
            }
        }

        /// Lets a released window fire: yields while a grid waits and no timer sleeps (the fire is on its way to
        /// the main actor). A window still asleep on the clock stops the wait at once.
        @MainActor func settle() async {
            for _ in 0..<500 where coalescer.isWaiting && clock.sleeperCount == 0 { await Task.yield() }
        }

        /// Yields enough turns for any fire that was released to land; for checks that nothing was sent.
        @MainActor func drain() async {
            for _ in 0..<50 { await Task.yield() }
        }
    }

    static func grid(_ columns: Int, _ rows: Int = 24) -> TerminalGridSize {
        TerminalGridSize(columns: columns, rows: rows)
    }

    /// (1) The first new grid is not sent at once: nothing before 25 ms, exactly one send at 25 ms, that grid.
    @Test func theFirstChangeIsSentOnceWhenItsWindowEnds() async throws {
        let rig = Rig()
        let a = Self.grid(100)
        rig.coalescer.viewSized(a)
        #expect(rig.sent.grids.isEmpty, "the first grid went at once")
        #expect(rig.coalescer.pending == a)
        try await rig.clock.waitForSleeper()
        #expect(rig.clock.sleeperDeadlines.map(\.offset) == [.milliseconds(25)])

        rig.clock.advance(by: .milliseconds(24))
        await rig.drain()
        #expect(rig.sent.grids.isEmpty, "the grid went before its window ended")

        rig.clock.advance(by: .milliseconds(1))
        await rig.settle()
        #expect(rig.sent.grids == [a])
        #expect(rig.sent.times == [.milliseconds(25)])
        #expect(rig.coalescer.pending == nil && !rig.coalescer.isWaiting)
        #expect(rig.coalescer.lastSent == a)

        rig.clock.advance(by: .milliseconds(100))
        await rig.drain()
        #expect(rig.sent.grids == [a], "a closed window sent again")
    }

    /// (2) Five changes inside one window send once: the newest.
    @Test func fiveChangesInsideOneWindowSendOnlyTheNewest() async throws {
        let rig = Rig()
        let grids = (0..<5).map { Self.grid(100 + $0) }
        rig.coalescer.viewSized(grids[0])
        try await rig.clock.waitForSleeper()
        for grid in grids.dropFirst() {
            rig.clock.advance(by: .milliseconds(4))
            await rig.drain()
            rig.coalescer.viewSized(grid)
            #expect(rig.clock.sleeperCount == 1, "a change inside the window opened another timer")
        }
        #expect(rig.sent.grids.isEmpty)
        #expect(rig.coalescer.pending == grids[4])

        rig.clock.advance(by: .milliseconds(9))
        await rig.settle()
        #expect(rig.sent.grids == [grids[4]])
        #expect(rig.sent.times == [.milliseconds(25)])

        rig.clock.advance(by: .milliseconds(100))
        await rig.drain()
        #expect(rig.sent.grids == [grids[4]])
    }

    /// (3) A change on every 120 Hz frame for 100 ms: sends at most every 25 ms, each the newest grid at its fire,
    /// and the final grid always goes.
    @Test func aChangeEveryFrameSendsAtMostEveryWindowAndAlwaysTheFinalGrid() async throws {
        let rig = Rig()
        var newest = [Duration: TerminalGridSize]()
        var latest: TerminalGridSize?
        var elapsed = Duration.zero
        var frames = 0
        while elapsed < .milliseconds(100) {
            let grid = Self.grid(80 + frames, 24 + frames % 3)
            rig.coalescer.viewSized(grid)
            latest = grid
            if rig.coalescer.isWaiting, rig.clock.sleeperCount == 0 { try await rig.clock.waitForSleeper() }
            let before = rig.sent.grids.count
            rig.clock.advance(by: Self.frame)
            elapsed += Self.frame
            await rig.settle()
            if rig.sent.grids.count > before, let latest { newest[rig.sent.times.last ?? .zero] = latest }
            frames += 1
        }
        #expect(frames == 13)
        rig.clock.advance(by: TerminalGridReportCoalescer.defaultInterval)
        await rig.settle()
        if let time = rig.sent.times.last, newest[time] == nil, let latest { newest[time] = latest }

        #expect(rig.sent.grids.count >= 3, "a 100 ms resize sent \(rig.sent.grids.count) grids")
        #expect(rig.sent.grids.count <= 5, "more than one send per 25 ms: \(rig.sent.times)")
        for (earlier, later) in zip(rig.sent.times, rig.sent.times.dropFirst()) {
            #expect(later - earlier >= .milliseconds(25), "two sends \(later - earlier) apart: \(rig.sent.times)")
        }
        for (grid, time) in zip(rig.sent.grids, rig.sent.times) {
            #expect(grid == newest[time], "at \(time) the send was \(grid), the newest grid was \(String(describing: newest[time]))")
        }
        #expect(rig.sent.grids.last == latest, "the final grid was not sent")
        #expect(Set(rig.sent.grids).count == rig.sent.grids.count, "a grid was sent twice")
        #expect(!rig.coalescer.isWaiting)
    }

    /// (4) A grid that changes back to the last sent grid sends nothing, whether it arrives with nothing waiting
    /// or replaces the waiting grid before the fire.
    @Test func aChangeBackToTheLastSentGridSendsNothing() async throws {
        let rig = Rig()
        let a = Self.grid(100)
        let b = Self.grid(90)
        rig.coalescer.viewSized(a)
        try await rig.clock.waitForSleeper()
        rig.clock.advance(by: .milliseconds(25))
        await rig.settle()
        #expect(rig.sent.grids == [a])

        rig.coalescer.viewSized(a)
        #expect(!rig.coalescer.isWaiting, "the last sent grid opened a window")
        await rig.drain()
        #expect(rig.clock.sleeperCount == 0)

        rig.coalescer.viewSized(b)
        try await rig.clock.waitForSleeper()
        rig.clock.advance(by: .milliseconds(10))
        await rig.drain()
        rig.coalescer.viewSized(a)
        rig.clock.advance(by: .milliseconds(15))
        await rig.settle()
        await rig.drain()
        #expect(rig.sent.grids == [a], "the grid went back to the last sent one and was sent again")
        #expect(!rig.coalescer.isWaiting && rig.coalescer.lastSent == a)
    }

    /// (5) `flush()` (the gesture ended) sends the waiting grid at once and closes the window: the timer sends
    /// nothing more. With nothing waiting it sends nothing.
    @Test func flushSendsTheWaitingGridAtOnceAndClosesTheWindow() async throws {
        let rig = Rig()
        rig.coalescer.flush()
        #expect(rig.sent.grids.isEmpty, "a flush with nothing waiting sent")

        let a = Self.grid(100)
        let b = Self.grid(110)
        rig.coalescer.viewSized(a)
        try await rig.clock.waitForSleeper()
        rig.clock.advance(by: .milliseconds(8))
        rig.coalescer.viewSized(b)
        rig.coalescer.flush()
        #expect(rig.sent.grids == [b], "flush did not send the newest grid in its own turn")
        #expect(rig.sent.times == [.milliseconds(8)])
        #expect(!rig.coalescer.isWaiting && rig.clock.sleeperCount == 0, "flush left the window's timer running")

        rig.clock.advance(by: .milliseconds(50))
        await rig.drain()
        #expect(rig.sent.grids == [b], "the closed window's timer sent again")

        rig.coalescer.viewSized(b)
        rig.coalescer.flush()
        #expect(rig.sent.grids == [b], "a flush resent the last sent grid")
    }

    /// (6) `cancel()` drops the waiting grid: nothing is sent, and the next change opens a new window.
    @Test func cancelDropsTheWaitingGrid() async throws {
        let rig = Rig()
        let a = Self.grid(100)
        rig.coalescer.viewSized(a)
        try await rig.clock.waitForSleeper()
        rig.coalescer.cancel()
        #expect(rig.coalescer.pending == nil && rig.clock.sleeperCount == 0)
        rig.clock.advance(by: .milliseconds(50))
        await rig.drain()
        #expect(rig.sent.grids.isEmpty, "a cancelled grid was sent")
        #expect(rig.coalescer.lastSent == nil)

        rig.coalescer.viewSized(a)
        try await rig.clock.waitForSleeper()
        rig.clock.advance(by: .milliseconds(25))
        await rig.settle()
        #expect(rig.sent.grids == [a])
        #expect(rig.sent.times == [.milliseconds(75)])
    }

    /// The forced report (a new PTY owner) goes at once even when it equals the last sent grid, and drops the
    /// older waiting grid.
    @Test func reportNowSendsAtOnceEvenTheLastSentGrid() async throws {
        let rig = Rig()
        let a = Self.grid(100)
        rig.coalescer.reportNow(a)
        #expect(rig.sent.grids == [a])
        rig.coalescer.reportNow(a)
        #expect(rig.sent.grids == [a, a], "the forced report was skipped as a duplicate")

        rig.coalescer.viewSized(Self.grid(120))
        try await rig.clock.waitForSleeper()
        let c = Self.grid(130)
        rig.coalescer.reportNow(c)
        #expect(rig.sent.grids == [a, a, c])
        #expect(!rig.coalescer.isWaiting && rig.clock.sleeperCount == 0)
        rig.clock.advance(by: .milliseconds(50))
        await rig.drain()
        #expect(rig.sent.grids == [a, a, c], "the dropped window sent its older grid")
    }
}
