@testable import CmuxNextAgentPane
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// When the pool's next page is made after a chat adopted the last one (AgentPaneSpareRefiller, decision
/// 2026-11-16): after the page drew the chat and the settle, as one background task; never in the handout's turn,
/// never while an input event (a key, a click, a scroll) is in dispatch, and never while another chat's page on
/// screen has not drawn.
///
/// The settle runs on a clock the test moves and the frames fire by hand. No test polls: a test awaits the moment
/// the refiller's queue asks the scheduler for frames (its link starts), then fires frames until the queue stops
/// asking. A limit on the wall clock only ends a test that fails.
@MainActor @Suite struct AgentPaneSpareRefillerTests {
    /// What the refiller was given and what its makes did.
    @MainActor private final class Seen {
        /// An input event is in dispatch now (the app: its input dispatch context).
        var dispatching = false
        var made = 0
        /// Makes that ran while an input event was in dispatch. The rule is 0.
        var madeInInput = 0
        /// The chat pages on screen that have not drawn (the app: the wait for shown chats).
        var loading: [AgentPaneShownChatsWait.WhenPainted] = []
        /// What a page of `loading` runs once it drew.
        var drew: (() -> Void)?
    }

    /// A refiller on a scheduler whose frames the test fires, with its settle on a manual clock.
    @MainActor private final class Rig {
        let clock: ManualClock
        let seen: Seen
        let work: MainWorkScheduler
        let refills: AgentPaneSpareRefiller
        private let asks: Asks
        private let uptime: Uptime
        private var time = 10.0

        init() {
            let clock = ManualClock()
            let seen = Seen()
            let uptime = Uptime()
            let asks = Asks()
            let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: uptime.read)) { _ in FakeLink(asks) }
            self.clock = clock
            self.seen = seen
            self.asks = asks
            self.uptime = uptime
            self.work = work
            refills = AgentPaneSpareRefiller(on: work, clock: clock, inInput: { seen.dispatching }, loading: { seen.loading }) {
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

        /// The refiller queued a task for a frame (a make that is due): waits for the queue's ask for frames, then
        /// fires frames until the queue asks for no more. Background work can wait some frames for one with idle
        /// time, so the count of frames has a bound and no clock is read.
        func runQueued() async throws {
            try await asks.next()
            var fired = 0
            while !asks.stopped, fired < 60 {
                frame()
                fired += 1
            }
            try #require(asks.stopped, "the refiller's queue still asked for frames after \(fired) of them")
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

    /// When the refiller's queue asks the scheduler for frames (the link is made, or resumed) and when it stops
    /// (the link pauses).
    @MainActor private final class Asks {
        nonisolated struct NoFrames: Error, CustomStringConvertible {
            var description: String { "the refiller queued no task for a frame" }
        }

        /// The queue asks for no frames now.
        private(set) var stopped = true
        private var count = 0
        private var taken = 0
        private var waiter: CheckedContinuation<Void, Never>?

        func began() {
            stopped = false
            count += 1
            wake()
        }

        func ended() { stopped = true }

        private func wake() {
            waiter?.resume()
            waiter = nil
        }

        /// The next ask for frames that no call took yet. Only a test that fails waits `limit` on the wall clock.
        func next(within limit: Duration = .milliseconds(2_500)) async throws {
            if count == taken {
                let late = DemandTimer(owner: "AgentPaneSpareRefillerTests.asks", ledger: WakeupLedger())
                await withCheckedContinuation { (asked: CheckedContinuation<Void, Never>) in
                    waiter = asked
                    late.schedule(after: limit) { @MainActor [weak self] in self?.wake() }
                }
                late.cancel()
            }
            guard count > taken else { throw NoFrames() }
            taken = count
        }
    }

    @MainActor private final class FakeLink: FrameLink {
        private let asks: Asks
        var isPaused = false {
            didSet {
                guard isPaused != oldValue else { return }
                if isPaused { asks.ended() } else { asks.began() }
            }
        }

        init(_ asks: Asks) {
            self.asks = asks
            asks.began()
        }

        func invalidate() { asks.ended() }
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
        try await rig.runQueued()
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
        try await rig.runQueued()
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
        try await rig.runQueued()
        #expect(rig.refills.counts.heldForInput == 1, "the make that was due did not find the event in dispatch")
        #expect(rig.seen.made == 0, "a page was made while an input event was in dispatch")
        #expect(rig.refills.isOpening, "the refill ended without a page")
        // It does not ask every frame: more frames in the same dispatch count nothing.
        await rig.frames(20)
        #expect(rig.refills.counts.heldForInput == 1 && rig.seen.made == 0, "\(rig.refills.counts), made \(rig.seen.made)")

        // The settle ends again while the event is still in dispatch.
        try await rig.advance(by: AgentPaneSpareRefiller.settle)
        try await rig.runQueued()
        #expect(rig.refills.counts.heldForInput == 2 && rig.seen.made == 0, "\(rig.refills.counts), made \(rig.seen.made)")

        // The dispatch ended.
        rig.seen.dispatching = false
        try await rig.advance(by: AgentPaneSpareRefiller.settle)
        try await rig.runQueued()
        #expect(rig.seen.made == 1, "no page after the dispatch ended")
        #expect(rig.seen.madeInInput == 0, "a make ran while an input event was in dispatch")
        #expect(rig.refills.counts.makes == 1 && rig.refills.counts.heldForInput == 2, "\(rig.refills.counts)")
        #expect(!rig.refills.isOpening)
    }

    /// A second chat found no page and builds its own (a cold open). A make that is due while that chat's page has
    /// not drawn makes nothing: its main-thread tasks would land in that open. The settle starts again at the page's
    /// paint.
    @Test func noMakeRunsWhileAChatOnScreenHasNotDrawn() async throws {
        let rig = Rig()
        rig.refills.afterPaint { $0() }
        // The second chat's page loads before the first chat's settle ends.
        rig.seen.loading = [{ [seen = rig.seen] in seen.drew = $0 }]
        try await rig.advance(by: AgentPaneSpareRefiller.settle)
        try await rig.runQueued()
        #expect(rig.seen.made == 0, "a page was made while a chat on screen had not drawn")
        #expect(rig.refills.counts.heldForOpen == 1, "the make that was due did not find the chat that loads")
        #expect(rig.refills.isOpening, "the refill ended without a page")
        // More frames make nothing and ask nothing.
        await rig.frames(20)
        #expect(rig.seen.made == 0 && rig.refills.counts.heldForOpen == 1, "\(rig.refills.counts), made \(rig.seen.made)")

        // The second chat drew: the settle again, then the page.
        rig.seen.loading = []
        let paint = try #require(rig.seen.drew, "the held make did not ask the page for its paint")
        paint()
        try await rig.advance(by: AgentPaneSpareRefiller.settle - .milliseconds(1))
        await rig.frames(20)
        #expect(rig.seen.made == 0, "a page was made before the settle ended")
        rig.clock.advance(by: .milliseconds(1))
        try await rig.runQueued()
        #expect(rig.seen.made == 1, "no page after the chat drew")
        #expect(rig.refills.counts.makes == 1 && rig.refills.counts.heldForOpen == 1, "\(rig.refills.counts)")
        #expect(!rig.refills.isOpening)

        // A second paint report of that page comes late: nothing more is made.
        paint()
        await rig.frames(20)
        #expect(rig.clock.sleeperCount == 0, "a paint after the make began a settle")
        #expect(rig.refills.counts.makes == 1)
    }

    /// The chat that loads never draws: its tab was hidden, or it closed. The make is asked again after the
    /// shown-chats deadline, and a page that is on screen no more holds nothing: the pool is not left empty.
    @Test func aChatThatNeverDrawsIsAskedAboutAgain() async throws {
        let rig = Rig()
        rig.refills.afterPaint { $0() }
        rig.seen.loading = [{ _ in }]
        try await rig.advance(by: AgentPaneSpareRefiller.settle)
        try await rig.runQueued()
        #expect(rig.seen.made == 0 && rig.refills.counts.heldForOpen == 1, "\(rig.refills.counts), made \(rig.seen.made)")

        // Still on screen and not drawn at the deadline: held again.
        try await rig.advance(by: AgentPaneShownChatsWait.deadline)
        try await rig.runQueued()
        #expect(rig.seen.made == 0 && rig.refills.counts.heldForOpen == 2, "\(rig.refills.counts), made \(rig.seen.made)")

        // Its tab was hidden: at the next deadline the page is made.
        rig.seen.loading = []
        try await rig.advance(by: AgentPaneShownChatsWait.deadline)
        try await rig.runQueued()
        #expect(rig.seen.made == 1, "a chat that left the screen kept the pool empty")
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
        try await rig.runQueued()
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
