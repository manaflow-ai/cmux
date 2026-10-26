import CmuxNextBrowser
@testable import CmuxNextChromiumWarmup
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// When the warm start skips, what counts as an idle moment, and how its steps ride the launch's
/// scheduler (p08-startup-018): never before `startup_complete` for a hidden need, never with input
/// pending, `CefInitialize` inside its post, and no ChromiumWarmup timer during launch or without
/// input. An engine with no embedded runtime is unavailable; the start and spare steps run against a
/// fake engine (the runtime is process-wide).
@MainActor @Suite(.timeLimit(.minutes(1))) struct ChromiumWarmupTests {
    final class Clock { var now: TimeInterval = 100 }
    final class Flag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    let clock = Clock()
    let input = FakeInputTap()
    let pending: WarmupPendingInput
    let launch: StartupTestScheduler

    init() {
        let pending = WarmupPendingInput()
        self.pending = pending
        launch = StartupTestScheduler(input: pending)
    }

    func warmup(engine: any ChromiumWarmupEngine = CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()),
                trackingMenu: @escaping @MainActor () -> Bool = { false }) -> ChromiumWarmup {
        let clock = clock
        // A manual clock nobody advances: no deadline fires, so a test fires one by hand (`idleDeadline`).
        return ChromiumWarmup(engine: engine, input: input, startup: launch.startup, clock: ManualClock(),
                              now: { clock.now }, isTrackingMenu: trackingMenu)
    }

    /// Lets the warmup's wait for the load run to its request: the wait is a main-actor task queued
    /// before this yield, and the fake's load does not suspend (or was resumed before the yield).
    func loadWaitRuns() async {
        await Task.yield()
    }

    @Test func anUnavailableEngineNeverWarms() {
        let warmup = warmup()
        warmup.start(defaultIsChromium: { true })
        warmup.chromiumLikely(.restoredTab)
        launch.complete()
        launch.fire()
        #expect(warmup.reason == nil)
        #expect(input.liveSubscriptions == 0, "no wait for an idle moment, no input subscription")
        #expect(launch.startup.log.records.isEmpty, "nothing posted")
    }

    /// A hidden need (a restored Chromium tab, launch with Chromium as the default engine) neither maps
    /// nor starts Chromium during launch, and arms no ChromiumWarmup timer: both wait for startup_complete.
    @Test func aHiddenNeedWaitsForStartupComplete() async {
        let engine = FakeWarmupEngine(running: false)
        let warmup = warmup(engine: engine)
        warmup.chromiumLikely(.restoredTab)
        launch.startup.firstFrameCommitted()
        for _ in 0..<4 { launch.fire() }
        #expect(engine.preloads == 0, "the framework is not mapped during launch")
        #expect(engine.initialized.isEmpty)
        #expect(!warmup.idleTimerArmed, "no launch timer")
        launch.complete()
        launch.fire()
        #expect(engine.preloads == 1, "mapped after startup")
        await loadWaitRuns()
        launch.fire()
        #expect(engine.initialized == ["restoredTab"], "CefInitialize at the next idle frame")
        #expect(!warmup.idleTimerArmed, "no input, no timer")
        #expect(launch.startup.log.records.allSatisfy { $0.priority == .afterStartup && $0.destination == .main })
    }

    /// A person's signal (the palette, the "+" menu, the default switch) maps the framework at once, so
    /// a tab picked right after skips the cold load; CefInitialize still waits for startup_complete.
    @Test func aPersonSignalMapsAtOnceAndInitializesAfterStartup() async {
        let engine = FakeWarmupEngine(running: false)
        let warmup = warmup(engine: engine)
        warmup.chromiumLikely(.palette)
        #expect(engine.preloads == 1, "mapped on the signal's turn")
        await loadWaitRuns()
        launch.startup.firstFrameCommitted()
        for _ in 0..<4 { launch.fire() }
        #expect(engine.initialized.isEmpty, "held until startup completes")
        launch.complete()
        launch.fire()
        #expect(engine.initialized == ["palette"])
    }

    /// CefInitialize runs inside its scheduled post, so a pending key holds it, and the spare window
    /// follows at the next idle frame.
    @Test func cefInitializeRunsInsideItsPostNeverWithInputPending() async {
        launch.complete()
        let engine = FakeWarmupEngine(running: false)
        engine.inputPending = { [pending] in pending.pending }
        let warmup = warmup(engine: engine)
        warmup.chromiumLikely(.newTabMenu)
        await loadWaitRuns()
        pending.pending = true
        launch.fire()
        #expect(engine.initialized.isEmpty, "a pending key goes first")
        pending.pending = false
        launch.fire()
        #expect(engine.initialized == ["newTabMenu"])
        #expect(engine.pendingAtInitialize == [false])
        #expect(engine.prepared.isEmpty, "the spare is a step of its own")
        launch.fire()
        #expect(engine.prepared == [false])
        #expect(launch.startup.log.records.map(\.name.description) == ["ChromiumWarmup.cefInitialize", "ChromiumWarmup.spareWindow"])
    }

    /// The load ended late: CefInitialize waits for it, then for its post.
    @Test func cefInitializeWaitsForTheLoad() async {
        launch.complete()
        let engine = FakeWarmupEngine(running: false)
        engine.loaded = false
        let warmup = warmup(engine: engine)
        warmup.chromiumLikely(.defaultEngine)
        await loadWaitRuns()
        launch.fire()
        #expect(engine.initialized.isEmpty)
        #expect(launch.startup.log.records.isEmpty, "nothing posted before the load ends")
        engine.finishLoad()
        await loadWaitRuns()
        launch.fire()
        #expect(engine.initialized == ["defaultEngine"])
    }

    /// The request is not input: with no input in the quiet period, the post runs the step and no
    /// timer is armed.
    @Test func noInputMeansNoTimer() {
        launch.complete()
        let warmup = warmup()
        var ran = 0
        warmup.request("ChromiumWarmup.spareWindow") { ran += 1 }
        launch.fire()
        #expect(ran == 1)
        #expect(!warmup.idleTimerArmed)
        #expect(input.liveSubscriptions == 0)
    }

    /// Input the app had just before the request counts: the quiet period runs from it.
    @Test func inputBeforeTheRequestStartsTheQuietPeriod() {
        launch.complete()
        let warmup = warmup()
        input.deliver(InputEventRecord(type: .keyDown, timestamp: clock.now - 0.2))
        var ran = 0
        warmup.request("ChromiumWarmup.cefInitialize") { ran += 1 }
        launch.fire()
        #expect(ran == 0, "a key 200 ms ago")
        #expect(warmup.idleTimerArmed)
        clock.now += 0.6
        warmup.idleDeadline()
        launch.fire()
        #expect(ran == 1)
        #expect(!warmup.idleTimerArmed)
    }

    @Test func aStepNeverRunsWithInputPending() {
        launch.complete()
        let warmup = warmup()
        var ran = 0
        warmup.request("ChromiumWarmup.cefInitialize") { ran += 1 }
        pending.pending = true
        launch.fire()
        #expect(ran == 0, "a pending key goes first")
        pending.pending = false
        launch.fire()
        #expect(ran == 1)
    }

    /// Input while the step is pending arms the one idle timer for the rest of the quiet period;
    /// the deadline posts the step again and the post cancels the timer.
    @Test func inputArmsTheOneTimerAndThePostCancelsIt() {
        launch.complete()
        let warmup = warmup()
        var ran = 0
        warmup.request("ChromiumWarmup.cefInitialize") { ran += 1 }
        input.deliver(InputEventRecord(type: .keyDown, timestamp: 1))
        launch.fire()
        #expect(ran == 0, "a key came within the quiet period")
        #expect(warmup.idleTimerArmed, "armed after input")
        clock.now += 0.3
        input.deliver(InputEventRecord(type: .keyDown, timestamp: 2))
        clock.now += 0.5
        warmup.idleDeadline()
        #expect(ran == 0)
        #expect(warmup.idleTimerArmed, "re-armed for the rest of the quiet period")
        clock.now += 0.5
        warmup.idleDeadline()
        #expect(!warmup.idleTimerArmed, "cancelled at the post")
        #expect(ran == 0, "the step runs from its post, not from the timer")
        launch.fire()
        #expect(ran == 1)
    }

    /// Menu tracking is never idle: the step waits for its end with no timer, then one quiet period.
    @Test func menuTrackingWaitsForItsEnd() {
        launch.complete()
        let tracking = Flag(false)
        let warmup = warmup(trackingMenu: { tracking.value })
        var ran = 0
        warmup.request("ChromiumWarmup.spareWindow") { ran += 1 }
        tracking.value = true
        launch.fire()
        #expect(ran == 0)
        #expect(!warmup.idleTimerArmed, "no timer while a menu tracks")
        tracking.value = false
        warmup.menuTrackingEnded()
        #expect(warmup.idleTimerArmed, "one quiet period after the menu")
        clock.now += 0.75
        warmup.idleDeadline()
        launch.fire()
        #expect(ran == 1)
    }

    /// An app that is never idle for `maxWait` gives the step up: no timer, no subscription.
    @Test func aStepIsGivenUpAfterMaxWait() {
        launch.complete()
        let warmup = warmup()
        var ran = 0
        warmup.request("ChromiumWarmup.cefInitialize") { ran += 1 }
        input.deliver(InputEventRecord(type: .keyDown, timestamp: 1))
        launch.fire()
        #expect(warmup.idleTimerArmed)
        clock.now += 61
        input.deliver(InputEventRecord(type: .keyDown, timestamp: 2))
        warmup.idleDeadline()
        #expect(!warmup.idleTimerArmed)
        #expect(input.liveSubscriptions == 0)
        launch.fire()
        #expect(ran == 0)
    }

    /// A menu open longer than `maxWait` gives the step up at its end: no timer, no subscription, no step.
    @Test func aMenuOpenPastMaxWaitGivesTheStepUp() {
        launch.complete()
        let tracking = Flag(true)
        let warmup = warmup(trackingMenu: { tracking.value })
        var ran = 0
        warmup.request("ChromiumWarmup.spareWindow") { ran += 1 }
        launch.fire()
        #expect(input.liveSubscriptions == 1)
        clock.now += 61
        tracking.value = false
        warmup.menuTrackingEnded()
        #expect(!warmup.idleTimerArmed)
        #expect(input.liveSubscriptions == 0)
        launch.fire()
        #expect(ran == 0)
    }

    /// p13-webui-016: a spare window came up while the pages kind has none (`CEFSpareWindow.windowCameUp`
    /// reports `onSpareWindowNeeded`): the next idle moment, never the turn that asked, builds the next
    /// spare with the pages switch read then. Read again at each step: off, the step keeps no pages spare.
    @Test func eachSpareStepRunsAtAnIdleMomentAndReadsThePagesSwitchThen() {
        launch.complete()
        let engine = FakeWarmupEngine()
        let warmup = warmup(engine: engine)
        let pages = Flag(true)
        warmup.start(defaultIsChromium: { false }, pagesSpare: { pages.value })
        launch.fire()  // the launch check
        // The browser spare's window came up; the pages spare is missing.
        engine.onSpareWindowNeeded?()
        #expect(engine.prepared.isEmpty, "nothing is built on the turn that asked")
        launch.fire()
        #expect(engine.prepared == [true], "the pages spare is built at the idle moment")

        // A page took it: the next one at the next idle moment, now with pages off.
        pages.value = false
        engine.onSpareWindowNeeded?()
        launch.fire()
        #expect(engine.prepared == [true, false], "pages off: the step keeps no pages spare")
        warmup.stop()
    }

    /// p13-webui-016: `browser.defaultEngine` left Chromium, so pages no longer use it: the untaken
    /// pages spare closes at once; back on Chromium, the next idle moment builds it again. Before
    /// Chromium runs, nothing happens (the first spare step reads the switch itself).
    @Test func thePagesSpareFollowsTheSwitch() {
        launch.complete()
        let engine = FakeWarmupEngine()
        let warmup = warmup(engine: engine)
        let pages = Flag(true)
        warmup.start(defaultIsChromium: { false }, pagesSpare: { pages.value })
        launch.fire()  // the launch check

        engine.isRunning = false
        pages.value = false
        warmup.pagesSpareChanged()
        #expect(engine.droppedPages == 0 && engine.prepared.isEmpty, "no Chromium yet, no spare to drop")

        engine.isRunning = true
        warmup.pagesSpareChanged()
        #expect(engine.droppedPages == 1, "pages left Chromium: the pages spare closes")
        #expect(engine.prepared.isEmpty)

        pages.value = true
        warmup.pagesSpareChanged()
        #expect(engine.prepared.isEmpty, "not on the switch's turn")
        launch.fire()
        #expect(engine.prepared == [true])
        #expect(engine.droppedPages == 1)
        warmup.stop()
    }

    /// A step's wait hears the input tap (p04-input-012): a key-down, click or left drag restarts the
    /// quiet period, a key-up, button-up or modifier change does not, and the wait's end drops the
    /// subscription.
    @Test func aWaitHearsTheTapUntilItEnds() {
        let warmup = warmup()
        let policy = ChromiumWarmup.Policy()
        warmup.request("ChromiumWarmup.spareWindow") {}
        #expect(input.liveSubscriptions == 1)
        #expect(input.classes == [.key, .button, .drag, .scroll, .pointerMove], "no modifier changes and no gestures")
        clock.now += 1
        #expect(warmup.isIdle(policy))
        for type: InputEventType in [.keyUp, .flagsChanged, .leftMouseUp, .rightMouseDragged, .magnify] {
            input.deliver(InputEventRecord(type: type, timestamp: 1))
        }
        #expect(warmup.isIdle(policy), "ups, right drags, modifier changes and gestures leave the quiet period")
        input.deliver(InputEventRecord(type: .keyDown, timestamp: 1))
        #expect(!warmup.isIdle(policy), "a key-down restarts it")
        clock.now += 0.7
        #expect(!warmup.isIdle(policy))
        clock.now += 0.1
        #expect(warmup.isIdle(policy), "one quiet period after the key")
        input.deliver(InputEventRecord(type: .leftMouseDragged, timestamp: 2))
        #expect(!warmup.isIdle(policy), "a left drag restarts it")
        warmup.stop()
        #expect(input.liveSubscriptions == 0, "the wait's end drops the subscription")
        clock.now += 1
        input.deliver(InputEventRecord(type: .keyDown, timestamp: 3))
        #expect(warmup.isIdle(policy), "after the wait no input is heard")
    }

    @Test func idleOnceTheQuietPeriodPasses() {
        let warmup = warmup()
        var policy = ChromiumWarmup.Policy()
        policy.idleInput = .milliseconds(750)
        warmup.noteInput()
        clock.now += 0.5
        #expect(!warmup.isIdle(policy))
        clock.now += 0.5
        #expect(warmup.isIdle(policy))
    }

    @Test func inputRestartsTheQuietPeriod() {
        let warmup = warmup()
        let policy = ChromiumWarmup.Policy()
        warmup.noteInput()
        clock.now += 1
        warmup.noteInput()
        #expect(!warmup.isIdle(policy))
    }

    @Test func menuTrackingIsNeverIdle() {
        let warmup = warmup(trackingMenu: { true })
        clock.now += 60
        #expect(!warmup.isIdle(ChromiumWarmup.Policy()))
    }

    @Test func theDefaultPolicy() {
        let policy = ChromiumWarmup.Policy()
        #expect(policy.idleInput == .milliseconds(750))
        #expect(policy.maxWait == .seconds(60))
        #expect(policy.recentUse == 7 * 24 * 60 * 60)
    }
}

/// The budget's pending-input check, set by hand.
@MainActor
final class WarmupPendingInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

/// Records the warmup's start and spare steps; runs no Chromium.
@MainActor private final class FakeWarmupEngine: ChromiumWarmupEngine {
    var availability: BrowserEngineAvailability = .available
    var isRunning: Bool
    /// Whether the framework load already ended (`libraryLoadEnded` returns at once).
    var loaded = true
    /// Read when `initializeLoaded` runs.
    var inputPending: @MainActor () -> Bool = { false }
    private(set) var preloads = 0
    /// The reason of each `initializeLoaded` call.
    private(set) var initialized: [String] = []
    /// `inputPending` at each `initializeLoaded` call.
    private(set) var pendingAtInitialize: [Bool] = []
    /// The `pages` argument of each `prepareSpareWindow` call.
    private(set) var prepared: [Bool] = []
    private(set) var droppedPages = 0
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    var onSpareWindowNeeded: (@MainActor () -> Void)?

    init(running: Bool = true) { isRunning = running }

    func usedRecently(within window: TimeInterval) async -> Bool { false }
    func preload() { preloads += 1 }

    func libraryLoadEnded() async {
        guard !loaded else { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    /// The load ended: the waiters resume.
    func finishLoad() {
        loaded = true
        let waiters = loadWaiters
        loadWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func initializeLoaded(reason: String) -> Bool {
        initialized.append(reason)
        pendingAtInitialize.append(inputPending())
        isRunning = true
        return true
    }

    func prepareSpareWindow(pages: Bool) -> Bool {
        prepared.append(pages)
        return true
    }

    func dropPagesSpareWindow() { droppedPages += 1 }
}
