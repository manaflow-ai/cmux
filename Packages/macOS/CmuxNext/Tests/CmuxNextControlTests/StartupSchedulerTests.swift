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

    @Test func aMissedFirstFrameRunsTheWorkButIsNoCommittedFrame() {
        let f = StartupFixture()
        f.startup.post(.afterFirstFrame, "Updater.start", on: .main) { [ran = f.ran] in ran.names.append("Updater.start") }
        f.startup.finishRegistration()
        f.startup.firstFrameMissed(nil)
        f.fire()
        #expect(f.ran.names == ["Updater.start"], "the work waiting for the frame runs after the deadline")
        f.hand.drain()
        #expect(f.startup.completion == nil, "a missed deadline is not a committed frame")
        #expect(f.startup.heldRefs == ["Startup.firstFrame"])
        f.startup.firstFrameCommitted()
        f.hand.drain()
        #expect(f.startup.completion?.reason == .firstFrameCommitted, "the late frame ends the ref")
        f.fire()
        #expect(f.ran.names == ["Updater.start"], "the released work ran once")
    }

    /// Work that measures the frame waits for a committed frame, not for a missed deadline.
    @Test func whenFirstFrameCommittedWaitsForTheRealFrameNotAMissedOne() {
        let f = StartupFixture()
        f.startup.whenFirstFrameCommitted { [ran = f.ran] in ran.names.append("Census.early") }
        f.startup.finishRegistration()
        f.startup.firstFrameMissed(nil)
        f.hand.drain()
        #expect(f.ran.names.isEmpty, "a reveal-deadline release is not the frame")
        f.startup.firstFrameCommitted()
        f.startup.firstFrameCommitted()
        #expect(f.ran.names == ["Census.early"], "once, at the late frame")
        f.startup.whenFirstFrameCommitted { [ran = f.ran] in ran.names.append("Census.late") }
        #expect(f.ran.names == ["Census.early", "Census.late"], "after the frame: at once")
    }

    @Test func whenFirstFrameCommittedNeverRunsForALaunchWithNoFrameOrAfterQuit() {
        let f = StartupFixture()
        f.startup.whenFirstFrameCommitted { [ran = f.ran] in ran.names.append("Census") }
        f.startup.finishRegistration()
        f.startup.firstFrameMissed(.noWindow)
        f.hand.drain()
        #expect(f.ran.names.isEmpty, "a windowless launch drew no frame")
        f.startup.beginQuit()
        f.startup.firstFrameCommitted()
        f.startup.whenFirstFrameCommitted { [ran = f.ran] in ran.names.append("Census.afterQuit") }
        #expect(f.ran.names.isEmpty)
    }

    @Test func aFirstFrameThatWillNeverComeEndsWithItsReason() {
        let f = StartupFixture()
        f.startup.finishRegistration()
        f.startup.firstFrameMissed(.noWindow)
        f.startup.firstFrameCommitted()
        f.hand.drain()
        #expect(f.startup.completion?.reason == .noWindow, "not firstFrameCommitted: the launch drew no frame")
    }

    @Test func afterFirstFrameReturnsOnceTheFirstFrameReleasedItsTasks() async {
        let f = StartupFixture()
        let waiter = Task { @MainActor [ran = f.ran] in
            await f.startup.afterFirstFrame()
            ran.names.append("Control.start")
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(f.ran.names.isEmpty, "the control socket waited for the first frame")
        f.startup.firstFrameCommitted()
        await waiter.value
        #expect(f.ran.names == ["Control.start"])
        await f.startup.afterFirstFrame()
        f.startup.finishRegistration()
        f.hand.drain()
        #expect(f.startup.completion?.reason == .registrationFinished, "waiting took no ref")
    }

    @Test func afterFirstFrameReturnsWhenQuitBegins() async {
        let f = StartupFixture()
        let waiter = Task { @MainActor in await f.startup.afterFirstFrame() }
        for _ in 0..<10 { await Task.yield() }
        f.startup.beginQuit()
        await waiter.value
        await f.startup.afterFirstFrame()
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

    @Test func theWatchdogThreadReadsTheMainTaskThatIsBlockingMain() {
        let f = StartupFixture()
        let log = f.startup.log
        let seen = StartupLaneRan()
        f.startup.post(.critical, "Theme.apply", on: .main) {
            let read = DispatchSemaphore(value: 0)
            // The hang watchdog's thread reads while this main task is stuck.
            Thread.detachNewThread {
                seen.add("\(log.currentMainTask ?? "none") main=\(Thread.isMainThread)")
                read.signal()
            }
            // concurrency-allow: a test's stand-in for a hung main task; the reader thread signals right after its read.
            read.wait()
        }
        #expect(seen.names == ["Theme.apply main=false"])
        #expect(log.currentMainTask == nil)
    }

    @Test func aDroppedRefHoldsStartupUntilTheFailsafe() async throws {
        let f = StartupFixture()
        // A restore closure that captured its ref is freed without calling it: the ref is gone, unreleased.
        func takeAndDrop(_ startup: StartupScheduler) { _ = startup.hold("Restore.lost") }
        takeAndDrop(f.startup)
        // The next refs may get the freed ref's memory; their release must not end the lost hold.
        for _ in 0..<8 { f.startup.hold("Pane.visible").release(.visiblePaneLoadedIdle) }
        f.complete()
        #expect(f.startup.completion == nil, "the lost ref still holds startup")
        #expect(f.startup.heldRefs == ["Restore.lost"])
        try await f.clock.waitForSleeper()
        f.clock.advance(by: StartupScheduler.failsafeTimeout)
        let completion = await withCheckedContinuation { (continuation: CheckedContinuation<StartupScheduler.Completion, Never>) in
            f.startup.whenComplete { continuation.resume(returning: $0) }
        }
        #expect(completion.reason == .failsafe, "the lost ref shows in the reason histogram")
    }

    @Test func theLaunchPhaseSettleIsARefAndItsFailsafeIsTheOnlyOne() {
        let phase = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let f = StartupFixture(phase: phase)
        f.startup.post(.afterStartup, "Palette.prepare", on: .main) { [ran = f.ran] in ran.names.append("Palette.prepare") }
        #expect(!f.startup.failsafeArmed, "the phase's settle failsafe is the deadline")
        #expect(f.clock.sleeperCount == 0)
        f.complete()
        #expect(f.startup.completion == nil, "the phase has not settled")
        #expect(f.startup.heldRefs == ["Startup.launchPhase"])
        phase.noteFirstFrame()
        for reference in [StartupPhase.Reference.firstSnapshot, .restoreDone, .visiblePageIdle] { phase.markDone(reference) }
        #expect(phase.phase == .settled)
        f.hand.drain()
        #expect(f.startup.completion?.reason == .firstFrameCommitted, "the settle names no reason: the one released before it")
        f.fire()
        #expect(f.ran.names == ["Palette.prepare"])
    }

    @Test func theLaunchPhaseFailsafeCompletesStartupWhateverIsHeld() async throws {
        let phaseClock = ManualClock()
        let phase = StartupPhase(clock: phaseClock, ledger: WakeupLedger())
        let f = StartupFixture(phase: phase)
        let restore = f.startup.hold("WindowManager.restore")
        f.complete()
        try await phaseClock.waitForSleeper()
        phaseClock.advance(by: .milliseconds(1_500))
        try await phaseClock.waitForSleeper()
        phaseClock.advance(by: .milliseconds(8_500))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            phase.whenReached(.settled) { continuation.resume() }
        }
        #expect(phase.settleCause == .failsafe)
        f.hand.drain()
        #expect(f.startup.completion?.reason == .failsafe, "one deadline and one reason end the launch")
        #expect(!restore.isReleased)
    }

    @Test func aRuleBrokenAfterCompletionIsStillRecorded() async {
        let f = StartupFixture()
        f.complete()
        f.startup.post(.afterStartup, "Cache.trim", on: .main) {}
        f.startup.post(.onDemand, "Lazy.service", on: .main) {}
        f.startup.post(.critical, "Mystery.step", on: .main) {}
        let startup = f.startup
        let (seen, report) = AsyncStream.makeStream(of: String.self)
        await Task.detached(priority: .medium) {
            startup.post(.critical, "Mystery.read", on: .lane(.files, .bestEffort)) { report.yield("Mystery.read") }
        }.value
        var reports = seen.makeAsyncIterator()
        let ranOnLane = await reports.next()
        #expect(ranOnLane == "Mystery.read")
        let violations = f.startup.log.violations
        #expect(violations.map(\.name.description) == ["Lazy.service", "Mystery.step", "Mystery.read"])
        #expect(violations.map(\.violation) == [.onDemandPosted, .notInCriticalAllowlist, .notInCriticalAllowlist])
        #expect(!f.startup.log.records.contains { $0.name.description == "Cache.trim" },
                "a post after completion that breaks no rule is not recorded")
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
        // The fixture's files lane is serial per priority: had the afterStartup post been submitted, it would run first.
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

    /// A post on a sequence runs after the sequence's earlier posts, off main, although the files lane runs two
    /// best-effort items at once: the managed-status writes, each a whole file, never land out of order.
    @Test func aSequencePostRunsAfterTheSequencesEarlierPosts() async {
        let f = StartupFixture()
        f.complete()
        // Its own work with the app's widths: two best-effort slots.
        let writes = BackgroundWork(label: "test.startup-sequence").sequence("test.status-writes")
        let (seen, report) = AsyncStream.makeStream(of: String.self)
        f.startup.post(.afterStartup, "Status.write", on: .sequence(writes, .bestEffort)) {
            // A slow write: outside the sequence, the next one would land first on the other slot.
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .milliseconds(50))
            report.yield("first main=\(Thread.isMainThread)")
        }
        f.startup.post(.afterStartup, "Status.write", on: .sequence(writes, .bestEffort)) { report.yield("second") }
        var reports = seen.makeAsyncIterator()
        let first = await reports.next()
        let second = await reports.next()
        #expect(first == "first main=false")
        #expect(second == "second")
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

    /// A value the completion's own mark must follow (`launch.views_built` before `startup_complete`)
    /// registers late and still runs before every earlier `whenComplete` observer.
    @Test func aFirstObserverRegisteredLateRunsBeforeTheEarlierObservers() {
        let f = StartupFixture()
        f.startup.whenComplete { [ran = f.ran] _ in ran.names.append("startup_complete") }
        f.startup.whenCompleteFirst { [ran = f.ran] _ in ran.names.append("views_built") }
        f.complete()
        #expect(f.ran.names == ["views_built", "startup_complete"])
        f.startup.whenCompleteFirst { [ran = f.ran] _ in ran.names.append("late") }
        #expect(f.ran.names == ["views_built", "startup_complete", "late"], "after completion it runs at once")
    }

    @Test func aFirstObserverNeverRunsAfterQuit() {
        let f = StartupFixture()
        var ran = false
        f.startup.whenCompleteFirst { _ in ran = true }
        f.startup.beginQuit()
        f.complete()
        #expect(!ran)
    }

    @Test func afterBeginQuitNoQueuedOrLaterLaneTaskRuns() async {
        let f = StartupFixture()
        f.startup.post(.afterStartup, "Launch.cleanup", on: .lane(.files, .bestEffort)) { [ran = f.laneRan] in ran.add("Launch.cleanup") }
        f.complete()
        let (lane, report) = AsyncStream.makeStream(of: String.self)
        let release = DispatchSemaphore(value: 0)
        // The fixture's files lane is serial per priority: this item holds it, so the items after it queue behind it.
        f.background.post(.bestEffort, mayBlock: .files) {
            report.yield("blocker")
            // concurrency-allow: a files-lane thread in a test, released below right after beginQuit.
            release.wait()
        }
        f.startup.post(.afterStartup, "Spares.trim", on: .lane(.files, .bestEffort)) { [ran = f.laneRan] in ran.add("Spares.trim") }
        var reports = lane.makeAsyncIterator()
        let blocking = await reports.next()
        #expect(blocking == "blocker")
        f.startup.beginQuit()
        f.startup.post(.critical, "Settings.read", on: .lane(.files, .bestEffort)) { [ran = f.laneRan] in ran.add("Settings.read") }
        // Behind every startup item on the lane: when it runs, each has run or been dropped.
        f.background.post(.bestEffort, mayBlock: .files) { report.yield("fence") }
        release.signal()
        let fence = await reports.next()
        #expect(fence == "fence")
        #expect(f.laneRan.names == ["Launch.cleanup"],
                "released at completion, it ran before quit; nothing queued at quit or posted after it runs")
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

/// The shared startup scheduler fixture with this suite's input source, critical allowlist and run records.
@MainActor
private final class StartupFixture {
    let scheduler: StartupTestScheduler
    let input: StartupTestInput
    let ran = StartupRan()
    let laneRan = StartupLaneRan()
    var clock: ManualClock { scheduler.clock }
    var hand: StartupTestHop { scheduler.hand }
    var background: BackgroundWork { scheduler.background }
    var startup: StartupScheduler { scheduler.startup }

    /// - Parameter phase: The launch phase of the frame scheduler (default: already settled, so the
    ///   scheduler arms its own failsafe on `clock`).
    init(phase: StartupPhase = .settled()) {
        let input = StartupTestInput()
        self.input = input
        // One files slot per priority, so an item that holds it queues the posts behind it.
        scheduler = StartupTestScheduler(phase: phase, input: input, criticalAllowlist: ["Theme.apply", "Settings.read"],
                                         background: BackgroundWork(filesWidths: .serial, label: "test.startup"))
    }

    /// One display frame, 17 ms after the last.
    func fire() { scheduler.fire() }

    /// Releases both implicit refs and runs the posted completion.
    func complete() { scheduler.complete() }
}

/// The names the tasks ran, in order.
@MainActor
private final class StartupRan {
    var names: [String] = []
}

/// Names recorded from lane and reader threads, in order.
private final class StartupLaneRan: Sendable {
    private let state = Mutex<[String]>([])

    var names: [String] { state.withLock { $0 } }

    func add(_ name: String) { state.withLock { $0.append(name) } }
}

@MainActor
private final class StartupTestInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}
