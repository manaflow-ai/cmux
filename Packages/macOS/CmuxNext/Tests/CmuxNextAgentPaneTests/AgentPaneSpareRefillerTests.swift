@testable import CmuxNextAgentPane
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// When the pool's next page is made after a chat adopted the last one (AgentPaneSpareRefiller, decision
/// 2026-11-16): after the page drew the chat and the settle, as one background task; never in the handout's turn,
/// and never while an input event (a key, a click, a scroll) is in dispatch.
///
/// The refiller also holds the pool's size rule (AgentPaneSpareDemand, decision 2026-11-16): the size follows a burst
/// of opens, each more page of that size is made at the next frame, and 60 s after the last open the pool is back to
/// its own count, as one background task that never runs while an input event is in dispatch.
///
/// The settle and the 60 s run on a clock the test moves and the frames fire by hand: no test waits on the wall clock
/// for a result.
@MainActor @Suite struct AgentPaneSpareRefillerTests {
    /// What the refiller was given and what its makes did.
    @MainActor private final class Seen {
        /// An input event is in dispatch now (the app: its input dispatch context).
        var dispatching = false
        var made = 0
        /// Makes that ran while an input event was in dispatch. The rule is 0.
        var madeInInput = 0
        /// The pages the pool can still make (the pool's part): each make adds one page while there is room.
        var room = 0
        /// The frame each make ran in.
        var madeInFrame: [Int] = []
        /// The sizes the refiller gave the pool, in order.
        var sizes: [Int] = []
        var frame = 0
    }

    /// A refiller on a scheduler whose frames the test fires, with its settle on a manual clock.
    @MainActor private final class Rig {
        let clock: ManualClock
        let seen: Seen
        let work: MainWorkScheduler
        let refills: AgentPaneSpareRefiller
        private let uptime: Uptime
        private var time = 10.0

        init() {
            let clock = ManualClock()
            let seen = Seen()
            let uptime = Uptime()
            let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: uptime.read)) { _ in FakeLink() }
            self.clock = clock
            self.seen = seen
            self.uptime = uptime
            self.work = work
            refills = AgentPaneSpareRefiller(on: work, clock: clock, inInput: { seen.dispatching }, room: { seen.room },
                                             resize: { seen.sizes.append($0) }) {
                seen.made += 1
                seen.madeInFrame.append(seen.frame)
                if seen.room > 0 { seen.room -= 1 }
                if seen.dispatching { seen.madeInInput += 1 }
            }
        }

        /// One display frame, on time (background work runs only in such a frame).
        func frame() {
            seen.frame += 1
            uptime.now += 16_700_000
            time += 0.0167
            work.frameDidFire(timestamp: time, refreshInterval: 1.0 / 60)
        }

        /// `count` frames, with a main-actor turn after each: a step of the settle that is due runs.
        func frames(_ count: Int) async {
            for _ in 0..<count {
                frame()
                await Task.yield()
            }
        }

        /// Frames until `reached`. The deadline on the wall clock only ends a test that fails.
        func frames(until reached: () -> Bool) async {
            let wall = ContinuousClock()
            let deadline = wall.now.advanced(by: .seconds(10))
            while !reached(), wall.now < deadline {
                frame()
                await Task.yield()
            }
        }

        /// `count` timers are asleep on the clock. The deadline on the wall clock only ends a test that fails.
        func asleep(_ count: Int) async {
            let wall = ContinuousClock()
            let deadline = wall.now.advanced(by: .seconds(10))
            while clock.sleeperCount != count, wall.now < deadline { await Task.yield() }
            #expect(clock.sleeperCount == count, "\(clock.sleeperCount) timers are asleep on the clock, not \(count)")
        }

        /// A timer is asleep on the clock, then the clock moves by `duration`.
        func advance(by duration: Duration) async throws {
            try await clock.waitForSleeper()
            clock.advance(by: duration)
        }
    }

    /// `CLOCK_UPTIME_RAW` nanoseconds the test moves (the frame budget's clock).
    @MainActor private final class Uptime {
        var now: UInt64 = 1_000_000_000
        var read: () -> UInt64 { { [self] in self.now } }
    }

    @MainActor private final class FakeLink: FrameLink {
        var isPaused = false
        func invalidate() {}
    }

    @Test func theNextPageFollowsTheChatsPaintThenTheSettle() async throws {
        let rig = Rig()
        var painted: (@MainActor () -> Void)?
        rig.refills.afterPaint { painted = $0 }
        #expect(rig.refills.isOpening)
        // The page has not drawn the chat: no settle runs, whatever the frames.
        await rig.frames(3)
        #expect(rig.clock.sleeperCount == 0, "the settle began before the page drew the chat")
        #expect(rig.seen.made == 0)

        let paint = try #require(painted)
        paint()
        try await rig.advance(by: AgentPaneSpareRefiller.settle - .milliseconds(1))
        await rig.frames(20)
        #expect(rig.seen.made == 0, "a page was made before the settle ended")

        rig.clock.advance(by: .milliseconds(1))
        await rig.frames(until: { rig.seen.made > 0 })
        #expect(rig.seen.made == 1, "no page followed the chat's paint and the settle")
        #expect(!rig.refills.isOpening)
        #expect(rig.refills.counts.makes == 1 && rig.refills.counts.heldForInput == 0, "\(rig.refills.counts)")
    }

    /// The handout is in the click's turn. A page that drew already (it refused the chat and kept its earlier paint)
    /// ends the wait at once, and still nothing is made in that turn or before the settle.
    @Test func nothingIsMadeInTheHandoutsTurn() async throws {
        let rig = Rig()
        rig.seen.dispatching = true
        rig.refills.afterPaint { $0() }
        #expect(rig.seen.made == 0, "a page was made in the handout's turn")
        rig.seen.dispatching = false
        await rig.frames(20)
        #expect(rig.seen.made == 0, "a page was made before the settle ended")
        try await rig.advance(by: AgentPaneSpareRefiller.settle)
        await rig.frames(until: { rig.seen.made > 0 })
        #expect(rig.seen.made == 1)
        #expect(rig.seen.madeInInput == 0)
    }

    /// A frame can come while an input event is in dispatch (a drag's or a menu's own run loop). The make that is
    /// due then makes nothing and waits the settle again; it runs once no event is in dispatch.
    @Test func noMakeRunsWhileAnInputEventIsInDispatch() async throws {
        let rig = Rig()
        rig.refills.afterPaint { $0() }
        // The event is in dispatch before the settle ends, so no frame can run the make first.
        rig.seen.dispatching = true
        try await rig.advance(by: AgentPaneSpareRefiller.settle)
        await rig.frames(until: { rig.refills.counts.heldForInput > 0 })
        #expect(rig.refills.counts.heldForInput == 1, "the make that was due did not find the event in dispatch")
        #expect(rig.seen.made == 0, "a page was made while an input event was in dispatch")
        #expect(rig.refills.isOpening, "the refill ended without a page")
        // It does not ask every frame: more frames in the same dispatch count nothing.
        await rig.frames(20)
        #expect(rig.refills.counts.heldForInput == 1 && rig.seen.made == 0, "\(rig.refills.counts), made \(rig.seen.made)")

        // The settle ends again while the event is still in dispatch.
        try await rig.advance(by: AgentPaneSpareRefiller.settle)
        await rig.frames(until: { rig.refills.counts.heldForInput > 1 })
        #expect(rig.refills.counts.heldForInput == 2 && rig.seen.made == 0, "\(rig.refills.counts), made \(rig.seen.made)")

        // The dispatch ended.
        rig.seen.dispatching = false
        try await rig.advance(by: AgentPaneSpareRefiller.settle)
        await rig.frames(until: { rig.seen.made > 0 })
        #expect(rig.seen.made == 1, "no page after the dispatch ended")
        #expect(rig.seen.madeInInput == 0, "a make ran while an input event was in dispatch")
        #expect(rig.refills.counts.makes == 1 && rig.refills.counts.heldForInput == 2, "\(rig.refills.counts)")
        #expect(!rig.refills.isOpening)
    }

    /// A second chat took a page while the first chat's refill waited: one page follows, after the second chat's
    /// paint. The first chat's wait does nothing more.
    @Test func aLaterHandoutRestartsTheWait() async throws {
        let rig = Rig()
        rig.refills.afterPaint { $0() }
        try await rig.clock.waitForSleeper()
        var painted: (@MainActor () -> Void)?
        rig.refills.afterPaint { painted = $0 }
        #expect(rig.clock.sleeperCount == 0, "the first chat's settle went on after the second handout")
        rig.clock.advance(by: AgentPaneSpareRefiller.settle)
        await rig.frames(20)
        #expect(rig.seen.made == 0, "the first chat's refill made a page before the second chat's page drew")

        let paint = try #require(painted)
        paint()
        try await rig.advance(by: AgentPaneSpareRefiller.settle)
        await rig.frames(until: { rig.seen.made > 0 })
        #expect(rig.seen.made == 1)
        #expect(rig.refills.counts.makes == 1)
    }

    /// The pool's quiet-input warm ran first (the page never drew the chat): the wait ends and makes nothing more.
    @Test func theQuietInputWarmEndsTheWait() async throws {
        let rig = Rig()
        var painted: (@MainActor () -> Void)?
        rig.refills.afterPaint { painted = $0 }
        #expect(rig.refills.settled(), "no open was pending after the handout")
        #expect(!rig.refills.isOpening)
        // The page draws late: its refill is over.
        let paint = try #require(painted)
        paint()
        await rig.frames(20)
        #expect(rig.clock.sleeperCount == 0, "a late paint began a settle after the pool's own warm ran")
        #expect(rig.seen.made == 0)
    }

    // MARK: The pool's size

    /// Three opens at once ask for three pages. After the settle the pages come one for each frame, and the row
    /// ends when the pool has no more room.
    @Test func eachMorePageOfABurstsSizeIsMadeAtTheNextFrame() async throws {
        let rig = Rig()
        rig.refills.asked()
        #expect(rig.seen.sizes.isEmpty, "one open changed the pool's size: \(rig.seen.sizes)")
        rig.refills.asked()
        rig.refills.asked()
        #expect(rig.seen.sizes == [2, 3] && rig.refills.size == 3, "\(rig.seen.sizes)")
        rig.refills.asked()
        #expect(rig.seen.sizes == [2, 3], "a fourth open raised the size over its bound: \(rig.seen.sizes)")

        rig.seen.room = 3
        rig.refills.afterPaint { $0() }
        #expect(rig.seen.made == 0, "a page was made in the handout's turn")
        // Two timers sleep on the clock: the refill's settle and the release. The settle ends first.
        await rig.asleep(2)
        rig.clock.advance(by: AgentPaneSpareRefiller.settle)
        await rig.frames(until: { rig.seen.made == 3 })
        #expect(rig.seen.made == 3, "\(rig.seen.made) of 3 pages were made")
        #expect(Set(rig.seen.madeInFrame).count == 3, "two pages were made in one frame: frames \(rig.seen.madeInFrame)")
        await rig.frames(20)
        #expect(rig.seen.made == 3, "a page was made with no room in the pool")
        #expect(rig.refills.counts.makes == 3)
    }

    /// A make that added no page (the pool cannot make one now: memory pressure, no window) ends the row.
    @Test func aMakeThatAddedNoPageEndsTheRow() async throws {
        let rig = Rig()
        let refills = AgentPaneSpareRefiller(on: rig.work, clock: rig.clock, room: { 2 }) { rig.seen.made += 1 }
        refills.afterPaint { $0() }
        try await rig.advance(by: AgentPaneSpareRefiller.settle)
        await rig.frames(until: { rig.seen.made > 0 })
        await rig.frames(20)
        #expect(rig.seen.made == 1, "the refiller asked \(rig.seen.made) times for a page the pool cannot make")
    }

    /// 60 s after the last open the pool is back to its own count: not before, and not while an input event is in
    /// dispatch.
    @Test func sixtySecondsAfterTheLastOpenThePoolIsBackToItsOwnCount() async throws {
        let rig = Rig()
        for _ in 0..<3 { rig.refills.asked() }
        try await rig.advance(by: AgentPaneSpareDemand.release - .milliseconds(1))
        await rig.frames(20)
        #expect(rig.seen.sizes == [2, 3] && rig.refills.counts.releases == 0, "the pool released pages before 60 s passed: \(rig.seen.sizes)")

        // The 60 s end while an event is in dispatch: nothing is released in that frame.
        rig.seen.dispatching = true
        rig.clock.advance(by: .milliseconds(1))
        await rig.frames(until: { rig.refills.counts.heldForInput > 0 })
        #expect(rig.refills.counts.heldForInput == 1 && rig.seen.sizes == [2, 3], "\(rig.refills.counts), sizes \(rig.seen.sizes)")

        rig.seen.dispatching = false
        try await rig.advance(by: AgentPaneSpareRefiller.settle)
        await rig.frames(until: { rig.refills.counts.releases > 0 })
        #expect(rig.seen.sizes == [2, 3, 1] && rig.refills.size == 1, "\(rig.seen.sizes)")
        #expect(rig.refills.counts.releases == 1)
        #expect(rig.clock.sleeperCount == 0, "a timer runs after the release")
    }

    /// An open 30 s after the burst: the 60 s count from that open.
    @Test func anOpenInTheMeantimeKeepsThePages() async throws {
        let rig = Rig()
        for _ in 0..<3 { rig.refills.asked() }
        try await rig.advance(by: .seconds(30))
        rig.refills.asked()
        try await rig.advance(by: .seconds(59))
        await rig.frames(20)
        #expect(rig.seen.sizes == [2, 3] && rig.refills.counts.releases == 0, "pages went 59 s after an open: \(rig.seen.sizes)")
        rig.clock.advance(by: .seconds(1))
        await rig.frames(until: { rig.refills.counts.releases > 0 })
        #expect(rig.seen.sizes == [2, 3, 1], "\(rig.seen.sizes)")
    }

    /// Memory pressure: the burst's count goes at once and no release is due. The pool's own count
    /// (`debug.new_tab capacity`) is the floor of the rule.
    @Test func forgetEndsTheBurstAndTheFloorStays() async throws {
        let rig = Rig()
        for _ in 0..<3 { rig.refills.asked() }
        rig.refills.forget()
        #expect(rig.seen.sizes == [2, 3, 1] && rig.refills.size == 1, "\(rig.seen.sizes)")
        await rig.frames(5)
        #expect(rig.clock.sleeperCount == 0, "a release is due after the burst's count went")

        #expect(rig.refills.keeps(atLeast: 2) == 2)
        rig.refills.asked()
        #expect(rig.seen.sizes == [2, 3, 1], "one open changed a pool of 2: \(rig.seen.sizes)")
        for _ in 0..<2 { rig.refills.asked() }
        #expect(rig.seen.sizes == [2, 3, 1, 3])
        try await rig.advance(by: AgentPaneSpareDemand.release)
        await rig.frames(until: { rig.refills.counts.releases > 0 })
        #expect(rig.seen.sizes == [2, 3, 1, 3, 2], "the release went below the pool's own count: \(rig.seen.sizes)")
    }
}
