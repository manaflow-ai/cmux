import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The launch scheduler (plans/cmux-next/chrome-parity/p08-startup.md, task 010): priorities,
/// destinations, refs, the failsafe and quit, as Chrome's AfterStartupTaskUtils orders them.
@MainActor @Suite(.timeLimit(.minutes(1))) struct StartupSchedulerTests {
    @Test func afterStartupNeverRunsBeforeEveryRefIsReleased() {
        let f = StartupFixture()
        f.startup.post(.afterStartup, "Palette.prepare", on: .main) { [ran = f.ran] in ran.names.append("Palette.prepare") }
        let restore = f.startup.hold("WindowManager.restore")
        f.startup.finishRegistration()
        f.startup.firstFrameCommitted()
        f.hand.drain()
        f.fire()
        f.fire()
        #expect(f.ran.names.isEmpty, "a ref is still held")
        #expect(f.startup.completion == nil)
        #expect(f.startup.heldRefs == ["WindowManager.restore"])
        restore.release(.visiblePaneLoadedIdle)
        #expect(f.startup.completion == nil, "the completion is posted to a later main turn, never run inline")
        f.hand.drain()
        #expect(f.startup.completion?.reason == .visiblePaneLoadedIdle)
        #expect(f.startup.completion?.heldTasks == 1)
        f.fire()
        #expect(f.ran.names == ["Palette.prepare"])
    }

    @Test func aRefTakenBeforeThePostedCompletionRunsHoldsStartupAgain() {
        let f = StartupFixture()
        f.startup.finishRegistration()
        f.startup.firstFrameCommitted()
        let late = f.startup.hold("Restore.late")
        f.hand.drain()
        #expect(f.startup.completion == nil, "the posted completion checks the refs again")
        late.release(.noVisiblePane)
        late.release(.visiblePaneTimedOut)
        f.hand.drain()
        #expect(f.startup.completion?.reason == .noVisiblePane, "a second release does nothing")
    }

    @Test func pendingInputDefersMainAfterStartupTasksOnePerFrame() {
        let f = StartupFixture()
        f.startup.post(.afterStartup, "Spares.prewarm", on: .main) { [ran = f.ran] in ran.names.append("Spares.prewarm") }
        f.complete()
        f.startup.post(.afterStartup, "IconPicker.warm", on: .main) { [ran = f.ran] in ran.names.append("IconPicker.warm") }
        f.input.pending = true
        f.fire()
        #expect(f.ran.names.isEmpty, "a pending key goes first")
        f.input.pending = false
        f.fire()
        #expect(f.ran.names == ["Spares.prewarm"], "one afterStartup main task per frame")
        f.fire()
        #expect(f.ran.names == ["Spares.prewarm", "IconPicker.warm"], "a post after completion goes straight to its class")
    }

    @Test func theFailsafeCompletesStartupWithItsReason() async throws {
        let f = StartupFixture()
        f.startup.post(.afterStartup, "Updater.start", on: .main) { [ran = f.ran] in ran.names.append("Updater.start") }
        f.startup.finishRegistration()
        // The first frame never comes (a stuck window server or a launch with no window).
        try await f.clock.waitForSleeper()
        #expect(f.startup.failsafeArmed)
        f.clock.advance(by: StartupScheduler.failsafeTimeout)
        let completion = await withCheckedContinuation { (continuation: CheckedContinuation<StartupScheduler.Completion, Never>) in
            f.startup.whenComplete { continuation.resume(returning: $0) }
        }
        #expect(completion.reason == .failsafe)
        #expect(completion.heldTasks == 1)
        #expect(!f.startup.failsafeArmed)
        f.fire()
        #expect(f.ran.names == ["Updater.start"])
    }

    @Test func postOrderIsKeptWithinEachPriority() {
        let f = StartupFixture()
        for name in ["Session.one", "Session.two", "Session.three"] as [StaticString] {
            f.startup.post(.afterStartup, name, on: .main) { [ran = f.ran] in ran.names.append(name.description) }
        }
        f.startup.post(.afterFirstFrame, "Sidebar.rows", on: .main) { [ran = f.ran] in ran.names.append("Sidebar.rows") }
        f.startup.post(.afterFirstFrame, "Panes.focused", on: .main) { [ran = f.ran] in ran.names.append("Panes.focused") }
        f.startup.post(.critical, "Theme.apply", on: .main) { [ran = f.ran] in ran.names.append("Theme.apply") }
        #expect(f.ran.names == ["Theme.apply"], "a critical task runs at once")
        f.fire()
        #expect(f.ran.names == ["Theme.apply"], "afterFirstFrame waits for the first frame")
        f.startup.firstFrameCommitted()
        f.fire()
        #expect(f.ran.names == ["Theme.apply", "Sidebar.rows", "Panes.focused"])
        f.startup.finishRegistration()
        f.hand.drain()
        for _ in 0..<4 { f.fire() }
        #expect(f.ran.names == ["Theme.apply", "Sidebar.rows", "Panes.focused", "Session.one", "Session.two", "Session.three"])
        #expect(f.startup.log.records.allSatisfy { $0.durationNanos != nil }, "every task has a record with its run")
        #expect(f.startup.log.currentMainTask == nil, "no task runs between tasks")
    }

    @Test func theRunningMainTaskIsTheWatchdogsCurrentTask() {
        let f = StartupFixture()
        let log = f.startup.log
        f.startup.post(.critical, "Theme.apply", on: .main) { [ran = f.ran] in
            ran.names.append(log.currentMainTask ?? "none")
            ran.names.append(log.phase.description)
        }
        #expect(f.ran.names == ["Theme.apply", "beforeFirstFrame"])
        #expect(log.currentMainTask == nil)
    }

    @Test func aCriticalNameOutsideTheAllowlistRunsAndIsRecorded() {
        let f = StartupFixture()
        f.startup.post(.critical, "Theme.apply", on: .main) {}
        f.startup.post(.critical, "Mystery.step", on: .main) { [ran = f.ran] in ran.names.append("Mystery.step") }
        f.startup.post(.onDemand, "Lazy.service", on: .main) { [ran = f.ran] in ran.names.append("Lazy.service") }
        #expect(f.ran.names == ["Mystery.step"])
        let violations = f.startup.log.violations
        #expect(violations.map(\.name.description) == ["Mystery.step", "Lazy.service"])
        #expect(violations.map(\.violation) == [.notInCriticalAllowlist, .onDemandPosted])
        f.complete()
        f.fire()
        #expect(f.ran.names == ["Mystery.step", "Lazy.service"], "an onDemand post runs as afterStartup")
    }

    @Test func lanePostsRunOffMainAndAfterStartupLanePostsWaitForCompletion() async {
        let f = StartupFixture()
        let (seen, report) = AsyncStream.makeStream(of: String.self)
        f.startup.post(.afterStartup, "Launch.cleanup", on: .lane(.files, .bestEffort)) {
            report.yield("Launch.cleanup main=\(Thread.isMainThread)")
        }
        // The files lane is serial per priority: had the afterStartup post been submitted, it would run first.
        f.startup.post(.critical, "Settings.read", on: .lane(.files, .bestEffort)) {
            report.yield("Settings.read main=\(Thread.isMainThread)")
        }
        var reports = seen.makeAsyncIterator()
        let first = await reports.next()
        #expect(first == "Settings.read main=false")
        f.complete()
        let second = await reports.next()
        #expect(second == "Launch.cleanup main=false")
        #expect(f.startup.log.records.map(\.destination) == [.lane(.files, .bestEffort), .lane(.files, .bestEffort)])
    }

    @Test func aBackgroundThreadPostHopsToMainAndIsQueuedOnce() async {
        let f = StartupFixture()
        let startup = f.startup
        let ran = f.ran
        await Task.detached(priority: .medium) {
            startup.post(.afterStartup, "Detached.step", on: .main) { ran.names.append("Detached.step") }
        }.value
        #expect(f.hand.count == 1, "one hop to main")
        f.hand.drain()
        #expect(f.startup.log.records.count == 1)
        f.complete()
        f.fire()
        f.fire()
        #expect(f.ran.names == ["Detached.step"])
    }

    @Test func aLanePostAfterCompletionGoesStraightToItsLane() async {
        let f = StartupFixture()
        f.complete()
        let startup = f.startup
        let (seen, report) = AsyncStream.makeStream(of: Bool.self)
        await Task.detached(priority: .medium) {
            startup.post(.afterStartup, "Cache.trim", on: .lane(.cpu, .idle)) { report.yield(Thread.isMainThread) }
        }.value
        #expect(f.hand.count == 0, "no hop to main after completion")
        var reports = seen.makeAsyncIterator()
        let onMain = await reports.next()
        #expect(onMain == false)
    }

    @Test func afterBeginQuitNothingRunsAndTheFailsafeIsCancelled() async throws {
        let f = StartupFixture()
        f.startup.post(.afterStartup, "Updater.start", on: .main) { [ran = f.ran] in ran.names.append("Updater.start") }
        f.startup.post(.afterFirstFrame, "Sidebar.rows", on: .main) { [ran = f.ran] in ran.names.append("Sidebar.rows") }
        let restore = f.startup.hold("WindowManager.restore")
        var completed = false
        f.startup.whenComplete { _ in completed = true }
        try await f.clock.waitForSleeper()
        f.startup.firstFrameCommitted()
        f.startup.beginQuit()
        #expect(!f.startup.failsafeArmed)
        #expect(f.clock.sleeperCount == 0, "the failsafe's sleep is cancelled")
        f.startup.post(.critical, "Theme.apply", on: .main) { [ran = f.ran] in ran.names.append("Theme.apply") }
        f.startup.finishRegistration()
        restore.release(.visiblePaneLoadedIdle)
        f.hand.drain()
        f.clock.advance(by: StartupScheduler.failsafeTimeout)
        for _ in 0..<3 { f.fire() }
        #expect(f.ran.names.isEmpty)
        #expect(f.startup.completion == nil, "the completion never fires during quit")
        #expect(!completed)
        #expect(f.startup.log.phase == .quitting)
    }

    @Test func noFailsafeTimerOutlivesCompletion() async throws {
        let f = StartupFixture()
        try await f.clock.waitForSleeper()
        f.complete()
        #expect(f.startup.completion?.reason == .firstFrameCommitted)
        #expect(!f.startup.failsafeArmed)
        #expect(f.clock.sleeperCount == 0)
        let late = f.startup.hold("Late.hold")
        #expect(late.isReleased, "a ref made after completion holds nothing")
        #expect(f.startup.heldRefs.isEmpty)
    }
}

/// A scheduler on hand-run frames, a hand-run main hop and a manual failsafe clock.
@MainActor
private final class StartupFixture {
    let clock: ManualClock
    let input: StartupTestInput
    let hand: StartupHandHop
    let uptime: StartupTestUptime
    let mainWork: MainWorkScheduler
    let startup: StartupScheduler
    let ran = StartupRan()
    private var timestamp = 0.0

    init() {
        let clock = ManualClock()
        let input = StartupTestInput()
        let hand = StartupHandHop()
        let uptime = StartupTestUptime()
        // The frame scheduler's stall timer sleeps on its own clock, so the failsafe is the only sleeper on `clock`.
        let mainWork = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: { uptime.now }),
                                                 clock: ManualClock(), ledger: WakeupLedger()) { _ in StartupTestLink() }
        self.clock = clock
        self.input = input
        self.hand = hand
        self.uptime = uptime
        self.mainWork = mainWork
        startup = StartupScheduler(mainWork: mainWork, background: BackgroundWork(label: "test.startup"), hop: hand.hop,
                                   clock: clock, ledger: WakeupLedger(), criticalAllowlist: ["Theme.apply", "Settings.read"],
                                   log: StartupTaskLog())
    }

    /// One display frame, 17 ms after the last.
    func fire() {
        uptime.now += 17_000_000
        timestamp += 1
        mainWork.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    /// Releases both implicit refs and runs the posted completion.
    func complete() {
        startup.finishRegistration()
        startup.firstFrameCommitted()
        hand.drain()
    }
}

/// The names the tasks ran, in order.
@MainActor
private final class StartupRan {
    var names: [String] = []
}

/// A main hop the test runs by hand.
private final class StartupHandHop: Sendable {
    private let queued = Mutex<[@MainActor @Sendable () -> Void]>([])

    var hop: StartupMainHop {
        StartupMainHop { [self] work in queued.withLock { $0.append(work) } }
    }

    var count: Int { queued.withLock { $0.count } }

    /// Runs every queued hop, and the hops they queue; returns how many ran.
    @MainActor @discardableResult func drain() -> Int {
        var ran = 0
        while true {
            let batch = queued.withLock { queued -> [@MainActor @Sendable () -> Void] in
                defer { queued = [] }
                return queued
            }
            if batch.isEmpty { return ran }
            for work in batch { work() }
            ran += batch.count
        }
    }
}

@MainActor
private final class StartupTestInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

private final class StartupTestUptime {
    var now: UInt64 = 1_000_000_000
}

private final class StartupTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
