import CmuxNextCompat
import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The launch's order owners at the composition root (p08-startup-012): the best-effort fence
/// `main()` raises comes down at startup complete, after the `startup_complete` marks, through the
/// init every order is made with (the app's order delegates to it).
@MainActor @Suite(.timeLimit(.minutes(1))) struct LaunchOrderTests {
    @Test func idleLaneWorkWaitsForCompletionThenRunsAfterTheMarks() async {
        let f = LaunchOrderFixture()
        let ran = LaunchOrderFlag()
        let (idleRan, idleDone) = AsyncStream<Void>.makeStream()
        f.background.post(.idle, mayBlock: .files) {
            ran.set()
            idleDone.finish()
        }
        f.order.startup.finishRegistration()
        f.hand.drain()
        #expect(f.marks.names.isEmpty, "the first-frame ref is still held")
        #expect(!ran.isSet, "idle lane work waits behind the fence until startup completes")
        f.order.startup.firstFrameCommitted()
        f.hand.drain()
        #expect(f.marks.names == ["startup_complete.firstFrameCommitted", "startup_complete"],
                "the reason first: a bench that waits for the mark has it")
        for await _ in idleRan {}
        #expect(ran.isSet, "the fence came down at completion")
    }

    /// p02-threads-114: the 3 s cap lowers the fence when startup has not completed; the completion then only
    /// records that the cap came first.
    @Test func theCapLowersTheFenceBeforeASlowCompletion() async throws {
        let f = LaunchOrderFixture()
        let (idleRan, idleDone) = AsyncStream<Void>.makeStream()
        f.background.post(.idle, mayBlock: .files) { idleDone.finish() }
        try await f.capClock.waitForSleeper()
        f.capClock.advance(by: BackgroundWork.LaunchFence.cap)
        for await _ in idleRan {}
        #expect(!f.fence.launch.isUp, "the cap lowered the fence with startup still held")
        f.complete()
        #expect(f.marks.names.last == LaunchOrder.fenceCappedMark)
        #expect(f.marks.names.filter { $0.hasPrefix("startup_complete.") }.count == 1,
                "the cap mark is no completion reason: startup_complete.<reason> holds only the reason")
    }

    @Test func aQuitBeforeCompletionNeverMarksTheCompletion() {
        let f = LaunchOrderFixture()
        f.order.startup.beginQuit()
        f.complete()
        #expect(f.marks.names.isEmpty, "the completion never fires after quit")
    }
}

/// A launch order on hand-run frames, a hand-run main hop and manual clocks, made on a raised
/// best-effort fence through the init the app's order delegates to.
@MainActor
final class LaunchOrderFixture {
    let scheduler: StartupTestScheduler
    let order: LaunchOrder
    /// The launch marks the order recorded, in order.
    let marks: LaunchOrderMarks
    var hand: StartupTestHop { scheduler.hand }
    var background: BackgroundWork { scheduler.background }

    /// The launch phase is already settled, so the scheduler arms its own failsafe (on a manual clock).
    init() {
        let scheduler = StartupTestScheduler(background: BackgroundWork(label: "test.launch-order"))
        let marks = LaunchOrderMarks(), capClock = ManualClock()
        (self.scheduler, self.marks, self.capClock) = (scheduler, marks, capClock)
        // The fence's cap sleeps on its own manual clock: a slow runner never lowers it before completion.
        fence = LaunchOrder.BestEffortFence(raisingOn: scheduler.background, clock: capClock)
        order = LaunchOrder(fence: fence, mainWork: scheduler.mainWork,
                            startup: scheduler.startup) { marks.names.append($0) }
    }

    /// The fence the order lowers.
    let fence: LaunchOrder.BestEffortFence
    /// The clock the fence's cap sleeps on.
    let capClock: ManualClock

    /// One display frame, 17 ms after the last.
    func fire() { scheduler.fire() }

    /// Releases both implicit refs and runs the posted completion.
    func complete() { scheduler.complete() }
}

/// The launch marks, in order.
@MainActor
final class LaunchOrderMarks {
    var names: [String] = []
}

/// Set once from a lane thread, read on main.
nonisolated final class LaunchOrderFlag: Sendable {
    private let state = Mutex<Bool>(false)

    var isSet: Bool { state.withLock { $0 } }

    func set() { state.withLock { $0 = true } }
}
