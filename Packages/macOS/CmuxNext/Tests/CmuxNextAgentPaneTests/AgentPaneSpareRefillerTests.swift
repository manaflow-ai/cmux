@testable import CmuxNextAgentPane
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// When the pool's next page is made after a chat adopted the last one (AgentPaneSpareRefiller, decision
/// 2026-11-16): after the page drew the chat and the settle, as one background task; never in the handout's turn,
/// and never while an input event (a key, a click, a scroll) is in dispatch.
///
/// The settle runs on a clock the test moves and the frames fire by hand: no test waits on the wall clock for a
/// result.
@MainActor @Suite struct AgentPaneSpareRefillerTests {
    /// What the refiller was given and what its makes did.
    @MainActor private final class Seen {
        /// An input event is in dispatch now (the app: its input dispatch context).
        var dispatching = false
        var made = 0
        /// Makes that ran while an input event was in dispatch. The rule is 0.
        var madeInInput = 0
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
            refills = AgentPaneSpareRefiller(on: work, clock: clock, inInput: { seen.dispatching }) {
                seen.made += 1
                if seen.dispatching { seen.madeInInput += 1 }
            }
        }

        /// One display frame, on time (background work runs only in such a frame).
        func frame() {
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

        /// The settle's timer is asleep on the clock, then the clock moves by `duration`.
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
}
