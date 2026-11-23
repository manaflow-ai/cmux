@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextWakeupsTestSupport
import Testing

/// T-KEYS (frame-owner-s4): a key resize or a divider drag changes a terminal's fit grid on almost every display
/// frame, and each report resized the PTY and sent SIGWINCH. ``TerminalGridReportCoalescer`` sends one resize per display
/// refresh, always the newest grid (RESIZE P0 6, Chromium's begin-frame rule); a window no refresh reaches ends at its
/// 25 ms timer (Ghostty.app's `min_ms`). Every test runs on a manual clock: the backstop is a `DemandTimer` deadline, so
/// nothing here waits on the wall clock.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalGridReportCoalescerTests {
    /// One 120 Hz display frame, rounded down to the nanosecond.
    static let frame: Duration = .nanoseconds(8_333_333)

    @MainActor final class Sent {
        var grids: [TerminalGridSize] = []
        var times: [Duration] = []
    }

    /// A window's display refreshes, stepped by hand (the window presenter's frame ticks in the app).
    @MainActor final class Ticks: TerminalGridReportTicks {
        private(set) var ticked: [TerminalGridReportCoalescer] = []
        private(set) var registrations = 0

        func tickGridReports(_ coalescer: TerminalGridReportCoalescer) {
            registrations += 1
            if !ticked.contains(where: { $0 === coalescer }) { ticked.append(coalescer) }
        }

        /// One refresh: each open window is ticked; a closed one is not ticked again.
        func refresh() {
            ticked.removeAll { !$0.frameTicked() }
        }
    }

    struct Rig {
        let clock: ManualClock
        let sent: Sent
        let coalescer: TerminalGridReportCoalescer
        let ticks: Ticks?

        @MainActor init(ticking: Bool = false) {
            let clock = ManualClock()
            let sent = Sent()
            let ticks = ticking ? Ticks() : nil
            self.clock = clock
            self.sent = sent
            self.ticks = ticks
            coalescer = TerminalGridReportCoalescer(clock: clock, ticks: { ticks }) { grid in
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
        // The newest grid at each send, in send order.
        var newestAtSend: [TerminalGridSize] = []
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
            if rig.sent.grids.count > before { newestAtSend.append(grid) }
            frames += 1
        }
        #expect(frames == 13)
        let beforeEnd = rig.sent.grids.count
        rig.clock.advance(by: TerminalGridReportCoalescer.defaultInterval)
        await rig.settle()
        if rig.sent.grids.count > beforeEnd, let latest { newestAtSend.append(latest) }

        #expect(rig.sent.grids.count >= 3, "a 100 ms resize sent \(rig.sent.grids.count) grids")
        #expect(rig.sent.grids.count <= 5, "more than one send per 25 ms: \(rig.sent.times)")
        for (earlier, later) in zip(rig.sent.times, rig.sent.times.dropFirst()) {
            #expect(later - earlier >= .milliseconds(25), "two sends \(later - earlier) apart: \(rig.sent.times)")
        }
        #expect(rig.sent.grids == newestAtSend, "a send was not the newest grid at its fire: \(rig.sent.times)")
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

    // MARK: Frame ticks (B3, diag bf2b674a: a 25 ms window's timer fired 124 ms late on a loaded runner)

    /// (7) RESIZE P0 6 (cause T): while frames run, a window ends at the next refresh of its window, not at the first one at
    /// or after 25 ms. A held key moves a pane 10-20 pt per 120 Hz refresh; one grid per 25 ms window (4 refreshes) left the
    /// program's own drawing 40-80 pt off its pane edge (px-keys-held-2-s1r x1, runner 2b757265: 63 frames, band 36 and
    /// edge 27). Chromium sends a new size with the next frame (visual properties at the begin-frame), never on a timer.
    /// Here: two changes in every refresh. The first of the first refresh goes at once (test (10), RESIZE P0 7); from then on
    /// each refresh already sent one, so its changes wait and only the newest goes at the next refresh: at most one per
    /// refresh, and the late timers send nothing more.
    @Test func whileFramesRunEachWindowEndsAtTheNextRefresh() async throws {
        let rig = Rig(ticking: true)
        let ticks = try #require(rig.ticks)
        var newest: [TerminalGridSize] = [Self.grid(102)]
        // No await between the refreshes: the timers' tasks get no turn, as on a busy main thread.
        for refresh in 1...4 {
            rig.coalescer.viewSized(Self.grid(100 + 2 * refresh))
            let grid = Self.grid(101 + 2 * refresh)
            rig.coalescer.viewSized(grid) // a second change in the same refresh: only it goes
            newest.append(grid)
            rig.clock.advance(by: Self.frame)
            ticks.refresh()
            #expect(rig.sent.grids == newest, "refresh \(refresh) did not send its newest grid: \(rig.sent.grids)")
            #expect(!rig.coalescer.isWaiting, "a grid still waits after refresh \(refresh)")
        }
        #expect(rig.sent.times == (0...4).map { Self.frame * $0 }, "the grids did not go at their refreshes: \(rig.sent.times)")

        // A refresh with no change sends nothing and ends the ticks, and the late timers send nothing.
        ticks.refresh()
        #expect(ticks.ticked.isEmpty, "a quiet coalescer is still ticked")
        rig.clock.advance(by: .milliseconds(100))
        await rig.drain()
        ticks.refresh()
        #expect(rig.sent.grids == newest, "a refresh with no change or a late timer sent again: \(rig.sent.grids)")
    }

    /// (8) No refresh comes (no frames run, or a test steps frames by hand): after the grid that went at once (test (10)),
    /// the timer ends the next window, and its grid goes once. A refresh that comes after the timer sends nothing more.
    @Test func withNoRefreshTheTimerEndsTheWindowAndTheGridGoesOnce() async throws {
        let rig = Rig(ticking: true)
        let ticks = try #require(rig.ticks)
        let first = Self.grid(99)
        rig.coalescer.viewSized(first)
        let a = Self.grid(100)
        rig.coalescer.viewSized(a)
        try await rig.clock.waitForSleeper()
        rig.clock.advance(by: .milliseconds(25))
        await rig.settle()
        #expect(rig.sent.grids == [first, a], "the timer did not end a window no refresh reached")
        #expect(rig.sent.times == [.zero, .milliseconds(25)])
        ticks.refresh()
        await rig.drain()
        #expect(rig.sent.grids == [first, a], "a refresh after the timer sent the grid twice")
        #expect(ticks.ticked.isEmpty)
    }

    /// (9) The refresh and the timer both come for one window (the timer's fire is on its way when the refresh ends the
    /// window): the grid goes once, at the one that comes first.
    @Test func aRefreshAndTheTimerForOneWindowSendItsGridOnce() async throws {
        let rig = Rig(ticking: true)
        let ticks = try #require(rig.ticks)
        let first = Self.grid(99)
        rig.coalescer.viewSized(first) // goes at once (test (10)): the next grid waits in a window
        let a = Self.grid(100)
        rig.coalescer.viewSized(a)
        try await rig.clock.waitForSleeper()
        // The clock passes the deadline: the timer's task is released but has not run yet; the refresh comes first.
        rig.clock.advance(by: .milliseconds(25))
        ticks.refresh()
        #expect(rig.sent.grids == [first, a])
        await rig.drain()
        #expect(rig.sent.grids == [first, a], "the timer sent the grid the refresh already sent")

        // The next window (that refresh sent a, so b waits): the timer first, then the refresh.
        let b = Self.grid(110)
        rig.coalescer.viewSized(b)
        try await rig.clock.waitForSleeper()
        rig.clock.advance(by: .milliseconds(25))
        await rig.settle()
        ticks.refresh()
        await rig.drain()
        #expect(rig.sent.grids == [first, a, b], "a window sent its grid twice or not at all: \(rig.sent.grids)")
    }

    /// (10) RESIZE P0 7 (cause T): while frames run, the grid of a size that just landed goes to the PTY in the landing's own
    /// turn, not at the next refresh. In a key spring the presenter's pass lands a size at the end of turn t; its grid waited
    /// for turn t+1's tick, so the program's redraw raced the next draw-ahead render and showed 3 refreshes after its pane
    /// (m20 allows 2): px-keys-held-2-s1r x1, fd7a1664 on cmux21 1x 120 Hz, 46 terminal frames (band 30, edge 16), every PTY
    /// grid 3-6 ms after the trace sample that showed its width. Chromium sends a new size at once and keeps one in flight.
    /// Here: the first grid after a refresh goes at once; a second one in the same refresh waits for the next refresh and goes
    /// there (newest only, at most one PTY resize per refresh); a refresh with no change sends nothing; the late timers send
    /// nothing more.
    @Test func whileFramesRunALandedGridGoesInItsOwnTurn() async throws {
        let rig = Rig(ticking: true)
        let ticks = try #require(rig.ticks)
        let a = Self.grid(100)
        rig.coalescer.viewSized(a)
        #expect(rig.sent.grids == [a], "the landed grid waited for the next refresh: \(rig.sent.grids)")
        #expect(rig.sent.times == [.zero])
        // A second size in the same refresh (a drag's second mouse move): it waits for the refresh, only the newest goes.
        rig.coalescer.viewSized(Self.grid(101))
        let b = Self.grid(102)
        rig.coalescer.viewSized(b)
        #expect(rig.sent.grids == [a], "two PTY resizes in one refresh: \(rig.sent.grids)")
        rig.clock.advance(by: Self.frame)
        ticks.refresh()
        #expect(rig.sent.grids == [a, b], "the refresh did not send the newest waiting grid: \(rig.sent.grids)")
        // That refresh sent b: a size that lands before the next refresh waits for it.
        let c = Self.grid(104)
        rig.coalescer.viewSized(c)
        #expect(rig.sent.grids == [a, b], "two PTY resizes in one refresh: \(rig.sent.grids)")
        rig.clock.advance(by: Self.frame)
        ticks.refresh()
        #expect(rig.sent.grids == [a, b, c])
        // A refresh with no change: the next landed size goes at once again (a key spring: one landing per refresh).
        rig.clock.advance(by: Self.frame)
        ticks.refresh()
        for step in 1...3 {
            let grid = Self.grid(104 + 2 * step)
            rig.coalescer.viewSized(grid)
            #expect(rig.sent.grids.last == grid, "spring refresh \(step): the landed grid did not go in its turn")
            rig.clock.advance(by: Self.frame)
            ticks.refresh()
        }
        #expect(rig.sent.grids.count == 6, "a grid was sent twice or not at all: \(rig.sent.grids)")
        ticks.refresh()
        #expect(ticks.ticked.isEmpty, "a quiet coalescer is still ticked")
        rig.clock.advance(by: .milliseconds(100))
        await rig.drain()
        #expect(rig.sent.grids.count == 6, "a late timer sent again: \(rig.sent.grids)")
        #expect(!rig.coalescer.isWaiting)
    }

    /// (11) Review of #37842 (finding 3): while frames run, every send spends the refresh, not only a send from
    /// `viewSized`. A forced report (`reportNow`, a new PTY owner) and then a live grid in the same refresh: the live grid
    /// waits for the next refresh, so the PTY still gets at most one resize per refresh.
    @Test func whileFramesRunAForcedReportSpendsItsRefresh() async throws {
        let rig = Rig(ticking: true)
        let ticks = try #require(rig.ticks)
        let forced = Self.grid(90)
        rig.coalescer.reportNow(forced)
        let a = Self.grid(100)
        rig.coalescer.viewSized(a)
        #expect(rig.sent.grids == [forced], "a forced report and a live grid went in one refresh: \(rig.sent.grids)")
        #expect(rig.coalescer.pending == a)
        rig.clock.advance(by: Self.frame)
        ticks.refresh()
        #expect(rig.sent.grids == [forced, a], "the next refresh did not send the waiting grid: \(rig.sent.grids)")
        rig.clock.advance(by: Self.frame)
        ticks.refresh()
        #expect(ticks.ticked.isEmpty, "a quiet coalescer is still ticked")
        let b = Self.grid(104)
        rig.coalescer.viewSized(b)
        #expect(rig.sent.grids == [forced, a, b], "after a quiet refresh the landed grid did not go at once")
        rig.clock.advance(by: .milliseconds(100))
        await rig.drain()
        #expect(rig.sent.grids == [forced, a, b], "a late timer sent again: \(rig.sent.grids)")
    }

    /// (12) RESIZE P0 8, review of #37964 (finding 1): a view shown into a key hold reports the grid of its pre-layout
    /// bounds (`waitsForRefresh`: never at once), and its pane's layout gives it its size in the same turn. That layout's
    /// grid goes at once (#37842's rule for a size that shows), not one refresh later behind the just-shown grid, and the
    /// just-shown grid never goes.
    @Test func aJustShownGridGivesWayToTheLayoutsGridAtOnce() async throws {
        let rig = Rig(ticking: true)
        let ticks = try #require(rig.ticks)
        rig.coalescer.viewSized(Self.grid(99), waitsForRefresh: true)
        #expect(rig.sent.grids.isEmpty, "the just-shown grid went at once: \(rig.sent.grids)")
        let laidOut = Self.grid(80)
        rig.coalescer.viewSized(laidOut)
        #expect(rig.sent.grids == [laidOut], "the layout's grid did not go in its turn: \(rig.sent.grids)")
        #expect(!rig.coalescer.isWaiting, "a grid still waits after the layout's grid went")
        rig.clock.advance(by: Self.frame)
        ticks.refresh()
        rig.clock.advance(by: .milliseconds(100))
        await rig.drain()
        #expect(rig.sent.grids == [laidOut], "the just-shown grid went later: \(rig.sent.grids)")
    }

    /// (13) RESIZE P0 11: a key spring's grid goes with the size drawn ahead for the next refresh, right after the pass. A
    /// key press before that refresh retargets the spring, and its turn draws the next refresh ahead again: that grid
    /// replaces one whose frame never shows, so it goes at once although the refresh is spent, and the grid drawn ahead
    /// after the next pass goes at once too. Waiting made it go at the next refresh's tick, which spent that refresh, so
    /// every later grid went at a tick, after the pass that showed it (px-keys-held-2-s1r, cmux21, build bffa4140: 2-4
    /// frames per press showed the program's picture of the previous grid).
    @Test func aGridThatReplacesAnUnshownGridGoesAtOnceAndTheNextRefreshsGridToo() async throws {
        let rig = Rig(ticking: true)
        let ticks = try #require(rig.ticks)
        let ahead = Self.grid(100)
        rig.coalescer.viewSized(ahead) // after the pass: drawn ahead for the next refresh
        #expect(rig.sent.grids == [ahead])
        let retargeted = Self.grid(98)
        rig.coalescer.viewSized(retargeted, replacesUnshown: true) // the key's turn, before the next refresh
        #expect(rig.sent.grids == [ahead, retargeted], "the grid that replaced an unshown one waited: \(rig.sent.grids)")
        #expect(!rig.coalescer.isWaiting)
        rig.clock.advance(by: Self.frame)
        ticks.refresh()
        let next = Self.grid(96)
        rig.coalescer.viewSized(next) // after that refresh's pass
        #expect(rig.sent.grids == [ahead, retargeted, next], "the next refresh's grid did not go in its turn: \(rig.sent.grids)")
        rig.clock.advance(by: .milliseconds(100))
        await rig.drain()
        #expect(rig.sent.grids == [ahead, retargeted, next], "a late timer sent again: \(rig.sent.grids)")
    }

    /// Review of #38125, finding 2: a burst of retargets in one refresh (scripted resizes) sends at most one grid at once
    /// in place of an unshown one; the next waits for the refresh, which sends the newest, and the refresh frees the rule.
    @Test func onlyOneGridPerRefreshGoesAtOnceInPlaceOfAnUnshownGrid() async throws {
        let rig = Rig(ticking: true)
        let ticks = try #require(rig.ticks)
        let ahead = Self.grid(100), first = Self.grid(98), second = Self.grid(96), third = Self.grid(94)
        rig.coalescer.viewSized(ahead)
        rig.coalescer.viewSized(first, replacesUnshown: true)
        rig.coalescer.viewSized(second, replacesUnshown: true)
        rig.coalescer.viewSized(third, replacesUnshown: true)
        #expect(rig.sent.grids == [ahead, first], "more than one grid went at once in one refresh: \(rig.sent.grids)")
        #expect(rig.coalescer.isWaiting)
        rig.clock.advance(by: Self.frame)
        ticks.refresh()
        #expect(rig.sent.grids == [ahead, first, third], "the refresh did not send the newest waiting grid: \(rig.sent.grids)")
        rig.clock.advance(by: Self.frame)
        ticks.refresh()
        let next = Self.grid(92)
        rig.coalescer.viewSized(next, replacesUnshown: true)
        #expect(rig.sent.grids == [ahead, first, third, next], "a later refresh's replacing grid waited: \(rig.sent.grids)")
    }
}
