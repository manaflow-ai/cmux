import CmuxNextWakeups
import CoreFoundation
import Foundation
import Testing

/// The main-thread scheduler's work batch (plans/cmux-next/sequence-manager-DESIGN.md section 2.3, step S2b): what a
/// posted task may start, and when, under a person's input; the progress floors that keep automation and background
/// moving while a person types; and the nested run loops of menu tracking, live resize and a drag session (R3, C4).
///
/// These are pins of today's rules: S2b moves the scheduler's class queues onto the sequence manager's queues and
/// keeps every rule, so each test passes on the base and on the head.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainWorkBatchTests {
    /// With a person's input pending, no posted task starts: not in the turn after the posts, not in the frame that
    /// shares the turn's window. A class runs its first task one frame later (it yielded a whole frame: the progress
    /// rule), in class order.
    @Test func noPostedTaskStartsWhileInputIsPendingUntilItsClassYieldedAFrame() {
        let clock = BatchClock()
        let input = BatchInput()
        let turns = BatchTurns()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read),
                                             performTurn: turns.perform) { _ in BatchLink() }
        let ran = BatchRecorder()
        input.pending = true
        for workClass in BudgetedWorkClass.allCases {
            work.post(workClass, owner: "batch.\(workClass)") { ran.append("\(workClass)") }
        }
        #expect(turns.runAll() == 1, "the posts on an idle scheduler queued one turn")
        #expect(ran.names.isEmpty, "the turn started a posted task ahead of the person's pending input")
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ran.names.isEmpty, "the frame in the turn's window started a posted task ahead of the pending input")
        clock.advance(ms: 17)
        work.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(ran.names == ["userBlocking", "visible", "automation", "background"],
                "each class yielded a whole frame: its first task runs though the input is still pending")
        #expect(BudgetedWorkClass.allCases.allSatisfy { work.postedCount($0) == 0 })
    }

    /// A class's share limits it only while input is pending: with none, ten 1 ms visible tasks use the frame time the
    /// other classes left (4 of them, up to the frame's 4 ms); under pending input the class keeps to its 2.5 ms share
    /// (3 of them) in the frame its progress rule lets it run.
    @Test func aSharesLimitHoldsOnlyWhileInputIsPending() {
        let clock = BatchClock()
        let input = BatchInput()
        let turns = BatchTurns()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read),
                                             performTurn: turns.perform) { _ in BatchLink() }
        let keeper = BatchLinkKeeper(on: work)
        var ran = 0
        for _ in 0..<10 {
            work.post(.visible, owner: "store.batch") {
                ran += 1
                clock.advance(ms: 1)
            }
        }
        var perFrame: [Int] = []
        for frame in 1...4 {
            if frame == 2 { input.pending = true }
            if frame == 4 { input.pending = false }
            let before = ran
            clock.advance(ms: 17)
            work.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 60)
            perFrame.append(ran - before)
        }
        #expect(perFrame == [4, 0, 3, 3],
                "no input: past the share up to the frame's 4 ms; input: nothing, then the 2.5 ms share; clear: the rest")
        keeper.stop()
    }

    /// Continuous typing (a key every 33 ms that expects a frame, input pending for 2 s, each tick rendered): visible
    /// runs every other frame, and automation and background each start a task at least once per 100 ms (the typing
    /// burst's floor, on the 60 Hz frame grid, plus the one frame an open input response holds a due task).
    @Test func progressFloorsHoldUnderContinuousTyping() {
        let clock = BatchClock()
        let input = BatchInput()
        let turns = BatchTurns()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read),
                                             performTurn: turns.perform) { _ in BatchLink() }
        let keeper = BatchLinkKeeper(on: work)
        let starts = BatchStarts()
        let flood = BatchFlood(work: work, clock: clock, starts: starts, cost: 100_000)
        for workClass in [BudgetedWorkClass.visible, .automation, .background] { flood.start(workClass, tasks: 50) }
        input.pending = true
        let start = clock.now
        let end = start + 2_000_000_000
        var nextKey = start
        var frame = 0
        while clock.now < end {
            let tick = start + UInt64(frame) * BatchClock.frame
            while nextKey <= tick {
                clock.set(max(nextKey, clock.now))
                work.noteDiscreteInput(expectsFrame: true)
                work.budget.noteTickRenderEnded() // the key's own commit
                nextKey += 33_000_000
            }
            clock.set(max(tick, clock.now))
            frame += 1
            work.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 60)
            work.budget.noteTickRenderEnded()
        }
        let floor = Self.burstInterval + 2 * BatchClock.frame + 1_000_000
        for workClass in [BudgetedWorkClass.automation, .background] {
            let gap = starts.longestGap(workClass, from: start, to: end)
            #expect(starts.count(workClass) >= 12, "\(workClass) ran \(starts.count(workClass)) tasks in 2 s of typing")
            #expect(gap <= floor, "\(workClass) waited \(gap) ns between tasks while a person typed")
        }
        let visibleGap = starts.longestGap(.visible, from: start, to: end)
        #expect(visibleGap <= Self.everyOtherFrame, "visible waited \(visibleGap) ns: more than every other frame")
        keeper.stop()
    }

    // MARK: Nested run loops (R3)

    /// Menu tracking: a posted task opens a menu, whose tracking loop runs the main run loop in event-tracking mode
    /// inside the task. A post made inside it, from main and from another thread, runs in that loop, before the menu
    /// closes: the batch runs in the common modes.
    @Test func postsRunInsideAMenuTrackingLoopThatAPostedTaskStarted() {
        Self.trackEventsAsTheAppDoes()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in BatchLink() }
        let ran = BatchRecorder()
        work.post(.visible, owner: "menu.open") {
            ran.append("menu opens")
            work.post(.automation, owner: "cli.request") { ran.append("automation") }
            let owner = work.board.owner("store.reply")
            work.postFromAnyThread(.visible, owner: owner) { ran.append("off-main reply") }
            Self.spin(mode: Self.eventTracking, seconds: 2) { ran.names.count >= 3 }
            ran.append("menu closes")
        }
        Self.spin(mode: .default, seconds: 5) { ran.names.contains("menu closes") }
        #expect(ran.names.first == "menu opens")
        #expect(ran.names.last == "menu closes")
        #expect(Set(ran.names.dropFirst().dropLast()) == ["automation", "off-main reply"],
                "a post made inside the menu's tracking loop waited for the menu to close: \(ran.names)")
    }

    /// Live resize: AppKit runs the main run loop in event-tracking mode while the mouse button is down, and the display
    /// link keeps ticking in it. With that input pending for 60 frames, every budgeted class still starts a task at
    /// least every other frame, and the frames' batches run in that mode.
    @Test func everyClassProgressesInALiveResizeTrackingLoop() {
        Self.trackEventsAsTheAppDoes()
        let clock = BatchClock()
        let input = BatchInput()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read)) { _ in BatchLink() }
        let keeper = BatchLinkKeeper(on: work)
        let starts = BatchStarts()
        let flood = BatchFlood(work: work, clock: clock, starts: starts, cost: 100_000)
        for workClass in BudgetedWorkClass.allCases { flood.start(workClass, tasks: 20) }
        input.pending = true
        let start = clock.now
        let pump = BatchFramePump(frames: 60) { frame in
            clock.set(max(start + UInt64(frame) * BatchClock.frame, clock.now))
            work.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 60)
        }
        pump.run(mode: Self.eventTracking)
        #expect(pump.fired == 60, "the frames did not tick in the tracking loop")
        for workClass in BudgetedWorkClass.allCases {
            let gap = starts.longestGap(workClass, from: start, to: clock.now)
            #expect(gap <= Self.everyOtherFrame, "\(workClass) waited \(gap) ns in the resize: more than every other frame")
        }
        input.pending = false
        keeper.stop()
    }

    /// A drag session: the mouse-down that starts it expects a frame (it opens an input response), and the drag's
    /// tracking loop renders no frame that closes the response. Automation and background still start within the
    /// response's 100 ms cap (plus the frame grid) of the mouse-down, and visible and userBlocking are never held by it.
    @Test func theInputResponseHoldsWorkNoLongerThanItsCapInADragSession() {
        Self.trackEventsAsTheAppDoes()
        let clock = BatchClock()
        let input = BatchInput()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read)) { _ in BatchLink() }
        let keeper = BatchLinkKeeper(on: work)
        let starts = BatchStarts()
        input.pending = true
        let mouseDown = clock.now
        work.noteDiscreteInput(expectsFrame: true)
        let flood = BatchFlood(work: work, clock: clock, starts: starts, cost: 100_000)
        for workClass in BudgetedWorkClass.allCases { flood.start(workClass, tasks: 20) }
        let pump = BatchFramePump(frames: 30) { frame in
            clock.set(max(mouseDown + UInt64(frame) * BatchClock.frame, clock.now))
            work.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 60)
        }
        pump.run(mode: Self.eventTracking)
        #expect(pump.fired == 30)
        let cap = Self.responseCap + Self.everyOtherFrame
        for workClass in [BudgetedWorkClass.automation, .background] {
            let first = starts.first(workClass).map { $0 - mouseDown }
            #expect(first != nil && first! <= cap, "\(workClass) first ran \(String(describing: first)) ns after the mouse-down")
        }
        for workClass in [BudgetedWorkClass.userBlocking, .visible] {
            let first = starts.first(workClass).map { $0 - mouseDown }
            #expect(first != nil && first! <= Self.everyOtherFrame,
                    "the input response held \(workClass) for \(String(describing: first)) ns")
        }
        input.pending = false
        keeper.stop()
    }

    // MARK: Helpers

    /// The typing burst's interval and the input response's cap (MainFrameBudget.InputResponse).
    private static let burstInterval: UInt64 = 100_000_000
    private static let responseCap: UInt64 = 100_000_000
    /// Two 60 Hz frames, plus the time the higher classes' tasks of a frame took before a class's first task (a frame
    /// holds at most 4 ms of scheduled work): what "every other frame" allows between two starts.
    private static let everyOtherFrame: UInt64 = 2 * BatchClock.frame + 5_000_000

    /// AppKit's event-tracking mode (menu tracking, live resize, drag sessions).
    private static let eventTracking = RunLoop.Mode("NSEventTrackingRunLoopMode")

    /// Makes event tracking one of the main run loop's common modes, as AppKit does for the app (a test process may
    /// have no NSApplication): what runs in the common modes runs in that loop.
    private static func trackEventsAsTheAppDoes() {
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: eventTracking.rawValue as CFString))
    }

    /// Runs main run loop passes in `mode` until `done` or `seconds`.
    private static func spin(mode: RunLoop.Mode, seconds: TimeInterval, until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: seconds)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: mode, before: Date(timeIntervalSinceNow: 0.01))
        }
    }
}

/// Fires `frames` frames from a timer in the common modes while the test runs the main run loop in a tracking mode, as
/// the display link ticks during live resize and drags.
@MainActor
private final class BatchFramePump {
    private let frames: Int
    private let onFrame: @MainActor (Int) -> Void
    private(set) var fired = 0

    init(frames: Int, onFrame: @escaping @MainActor (Int) -> Void) {
        self.frames = frames
        self.onFrame = onFrame
    }

    func run(mode: RunLoop.Mode) {
        let timer = Timer(timeInterval: 0.002, repeats: true) { [weak self] _ in
            // main-proof: the timer is only on the main run loop.
            MainActor.assumeIsolated { self?.fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        let end = Date(timeIntervalSinceNow: 10)
        while fired < frames, Date() < end {
            _ = RunLoop.main.run(mode: mode, before: Date(timeIntervalSinceNow: 0.01))
        }
        timer.invalidate()
    }

    private func fire() {
        guard fired < frames else { return }
        fired += 1
        onFrame(fired)
    }
}

/// A flood of tasks per class that never runs dry: each task records its start, takes `cost` on the test's clock and
/// posts one more of its class (that one waits for a later batch: a batch runs only what was posted before it began).
@MainActor
private final class BatchFlood {
    private let work: MainWorkScheduler
    private let clock: BatchClock
    private let starts: BatchStarts
    private let cost: UInt64

    init(work: MainWorkScheduler, clock: BatchClock, starts: BatchStarts, cost: UInt64) {
        self.work = work
        self.clock = clock
        self.starts = starts
        self.cost = cost
    }

    /// Posts `tasks` tasks of `workClass`, each of which posts its successor.
    func start(_ workClass: BudgetedWorkClass, tasks: Int) {
        for _ in 0..<tasks { post(workClass) }
    }

    private func post(_ workClass: BudgetedWorkClass) {
        work.post(workClass, owner: "flood.\(workClass)") { [weak self] in
            guard let self else { return }
            starts.note(workClass, at: clock.now)
            clock.advance(nanos: cost)
            post(workClass)
        }
    }
}

/// When each class's tasks started, on the test's clock.
@MainActor
private final class BatchStarts {
    private var starts: [BudgetedWorkClass: [UInt64]] = [:]

    func note(_ workClass: BudgetedWorkClass, at now: UInt64) { starts[workClass, default: []].append(now) }

    func count(_ workClass: BudgetedWorkClass) -> Int { starts[workClass]?.count ?? 0 }

    func first(_ workClass: BudgetedWorkClass) -> UInt64? { starts[workClass]?.first }

    /// The longest time between `from`, the class's starts and `to` (the floods never run dry).
    func longestGap(_ workClass: BudgetedWorkClass, from: UInt64, to: UInt64) -> UInt64 {
        var last = from
        var gap: UInt64 = 0
        for start in starts[workClass] ?? [] {
            gap = max(gap, start &- last)
            last = start
        }
        return max(gap, to &- last)
    }
}

/// The names of the tasks that ran, in order (a Sendable reply can capture it; a local var it cannot).
@MainActor
private final class BatchRecorder {
    private(set) var names: [String] = []
    func append(_ name: String) { names.append(name) }
}

/// The scheduler's run loop turns, run only when the test says (``MainWorkScheduler/TurnPerformer``).
@MainActor
private final class BatchTurns {
    private var queued: [@MainActor () -> Void] = []

    var perform: MainWorkScheduler.TurnPerformer { { [weak self] turn in self?.queued.append(turn) } }

    /// Runs the turns queued now; returns how many ran.
    @discardableResult
    func runAll() -> Int {
        let turns = queued
        queued.removeAll()
        for turn in turns { turn() }
        return turns.count
    }
}

/// A frame-class client that keeps the scheduler's fake link up, so posts wait for hand-fired frames.
@MainActor
private final class BatchLinkKeeper {
    private let client: FrameClient

    init(on work: MainWorkScheduler) {
        client = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        client.activate()
    }

    func stop() { client.deactivate() }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class BatchClock {
    /// One 60 Hz frame.
    static let frame: UInt64 = 16_666_667
    private(set) var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
    func advance(nanos: UInt64) { now += nanos }
    func set(_ value: UInt64) { now = value }
}

@MainActor
private final class BatchInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class BatchLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
