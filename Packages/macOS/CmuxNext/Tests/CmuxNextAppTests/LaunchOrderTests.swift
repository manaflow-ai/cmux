import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The launch's order owners at the composition root: the
/// best-effort fence `main()` raises comes down at the launch phase's reveal, through the init every
/// order is made with (the app's order delegates to it), and nothing else lowers it while launching.
/// Chrome: `ThreadPoolInstance::BeginBestEffortFence` / `EndBestEffortFence`
/// (base/task/thread_pool/thread_pool_instance.h), ended from the UI thread
/// (chrome/browser/after_startup_task_utils.cc).
@MainActor @Suite(.timeLimit(.minutes(1))) struct LaunchOrderTests {
    @Test func theCompletionMarksItsReasonFirst() {
        let f = LaunchOrderFixture()
        f.order.startup.finishRegistration()
        f.hand.drain()
        #expect(f.marks.names.isEmpty, "the first-frame ref is still held")
        f.order.startup.firstFrameCommitted()
        f.hand.drain()
        #expect(f.marks.names == ["startup_complete.firstFrameCommitted", "startup_complete"],
                "the reason first: a bench that waits for the mark has it")
    }

    /// While launching, a posted best-effort lane item queues on the fence and user-visible lane work runs
    /// at once; the first frame's reveal starts the held item.
    @Test func aBestEffortPostWaitsForTheRevealAndUserVisibleRunsAtOnce() async {
        let launch = LaunchOrderLaunch()
        let (f, queued, started) = (launch.fixture, launch.queued, launch.started)
        f.phase.noteLaunch(.window)
        f.background.post(.bestEffort, mayBlock: .files) { started.send("bestEffort") }
        #expect(await queued.next() == .bestEffort, "the fence holds a best-effort post while launching")
        f.background.post(.userVisible, mayBlock: .files) { started.send("userVisible") }
        #expect(await started.next() == "userVisible", "user-visible lane work runs at once")
        #expect(f.fence.launch.isUp)

        f.phase.noteFirstFrame()
        #expect(f.phase.phase == .revealed)
        #expect(!f.fence.launch.isUp, "the reveal lowers the fence")
        #expect(await started.next() == "bestEffort", "the reveal started the held item")
    }

    /// A hidden launch reveals at once (p06-scheduler.md section A), so the fence opens with it.
    @Test func aHiddenLaunchOpensTheFenceAtOnce() async {
        let launch = LaunchOrderLaunch()
        let (f, queued, started) = (launch.fixture, launch.queued, launch.started)
        f.background.post(.idle, mayBlock: .files) { started.send("idle") }
        #expect(await queued.next() == .idle)
        f.phase.noteLaunch(.hidden)
        #expect(!f.fence.launch.isUp)
        #expect(await started.next() == "idle")
    }

    /// The reveal starts the held items in post order: on a one-slot lane they run one after another, so the
    /// run order is the release order.
    @Test func theRevealStartsTheHeldItemsInPostOrder() async {
        let launch = LaunchOrderLaunch(cpuWidth: 1)
        let (f, queued, started) = (launch.fixture, launch.queued, launch.started)
        for index in 0..<3 {
            f.background.post(.bestEffort, mayBlock: .cpu) { started.send("item \(index)") }
        }
        for _ in 0..<3 { #expect(await queued.next() == .bestEffort) }
        f.phase.noteFirstFrame()
        var order: [String] = []
        for _ in 0..<3 { order.append(await started.next() ?? "none") }
        #expect(order == ["item 0", "item 1", "item 2"])
    }

    /// The fence has no timer of its own: with no first frame, it holds until the reveal deadline reveals
    /// the launch, and not a millisecond before (bench_launch.py `launch.order_ok`).
    @Test func onlyTheRevealDeadlineOpensTheFenceWithNoFirstFrame() async throws {
        let launch = LaunchOrderLaunch()
        let (f, queued, started) = (launch.fixture, launch.queued, launch.started)
        #expect(!f.fence.launch.capArmed, "no off-main cap could open the fence before the reveal")
        f.phase.noteLaunch(.window)
        f.background.post(.bestEffort, mayBlock: .files) { started.send("bestEffort") }
        #expect(await queued.next() == .bestEffort)
        try await launch.phaseClock.waitForSleeper()
        launch.phaseClock.advance(by: StartupPhase.Timing().revealDeadline - .milliseconds(1))
        #expect(f.phase.phase == .launching)
        #expect(f.fence.launch.isUp, "a millisecond short of the reveal deadline the fence holds")
        launch.phaseClock.advance(by: .milliseconds(1))
        await withCheckedContinuation { continuation in
            f.phase.whenReached(.revealed) { continuation.resume() }
        }
        #expect(f.phase.revealCause == .deadline)
        #expect(!f.fence.launch.isUp)
        #expect(await started.next() == "bestEffort")
    }

    /// An order made on a phase that already revealed lowers the fence at once.
    @Test func anOrderOnARevealedPhaseLowersTheFenceAtOnce() {
        let f = LaunchOrderFixture()
        #expect(!f.fence.launch.isUp)
    }

    @Test func aQuitBeforeCompletionNeverMarksTheCompletion() {
        let f = LaunchOrderFixture()
        f.order.startup.beginQuit()
        f.complete()
        #expect(f.marks.names.isEmpty, "the completion never fires after quit")
    }
}

/// A launching order: a launch phase on a manual clock, lanes that report each held post, and the
/// lane bodies' signals.
@MainActor
private final class LaunchOrderLaunch {
    /// The reveal deadline's clock.
    let phaseClock: ManualClock
    /// The priority of each post that had to wait, in order.
    let queued: LaunchOrderSignal<WorkPriority>
    /// What the lane bodies send when they run.
    let started = LaunchOrderSignal<String>()
    let fixture: LaunchOrderFixture

    init(cpuWidth: Int = BackgroundWork.defaultCPUWidth) {
        let phaseClock = ManualClock(), queued = LaunchOrderSignal<WorkPriority>()
        let background = BackgroundWork(cpuWidth: cpuWidth, label: "test.launch-order.fence",
                                        onQueued: { _, priority in queued.send(priority) })
        (self.phaseClock, self.queued) = (phaseClock, queued)
        fixture = LaunchOrderFixture(phase: StartupPhase(clock: phaseClock, ledger: WakeupLedger()), background: background)
    }
}

/// Values sent from lane bodies (synchronous, off the main actor), awaited by the test in send order.
/// Nonisolated: the module defaults to the main actor, and lane bodies call `send` from a lane thread.
private nonisolated struct LaunchOrderSignal<Value: Sendable>: Sendable {
    private let stream: AsyncStream<Value>
    private let continuation: AsyncStream<Value>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream(of: Value.self) }

    func send(_ value: Value) { continuation.yield(value) }

    func next() async -> Value? {
        for await value in stream { return value }
        return nil
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

    /// - Parameters:
    ///   - phase: The launch phase; the default is already settled, so the order lowers the fence at once and
    ///     the scheduler arms its own failsafe (on a manual clock).
    ///   - background: The lanes the fence holds.
    init(phase: StartupPhase = .settled(), background: BackgroundWork = BackgroundWork(label: "test.launch-order")) {
        let scheduler = StartupTestScheduler(phase: phase, background: background)
        let marks = LaunchOrderMarks()
        (self.scheduler, self.marks) = (scheduler, marks)
        fence = LaunchOrder.BestEffortFence(raisingOn: scheduler.background)
        order = LaunchOrder(fence: fence, mainWork: scheduler.mainWork,
                            startup: scheduler.startup) { marks.names.append($0) }
    }

    /// The fence the order lowers at the reveal.
    let fence: LaunchOrder.BestEffortFence
    /// The launch phase whose reveal lowers the fence.
    var phase: StartupPhase { scheduler.mainWork.startup }

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
