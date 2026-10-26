import CmuxNextBrowser
@testable import CmuxNextChromiumWarmup
import CmuxNextCompat
import CmuxNextInput
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// When the warm start skips, and what counts as an idle moment. An engine
/// with no embedded runtime is unavailable, so nothing here maps or starts
/// Chromium (the runtime is process-wide); the spare steps run against a fake engine.
@MainActor struct ChromiumWarmupTests {
    final class Clock { var now: TimeInterval = 100 }
    final class Flag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    let clock = Clock()
    let input = FakeInputTap()

    func warmup(engine: any ChromiumWarmupEngine = CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap()),
                memory: ManualMemoryLevelRegistry = ManualMemoryLevelRegistry(),
                trackingMenu: @escaping @MainActor () -> Bool = { false }) -> ChromiumWarmup {
        let clock = clock
        // A manual clock nobody advances: no deadline fires, so a test's wait ends only when it says.
        return ChromiumWarmup(engine: engine, input: input, memory: memory, clock: ManualClock(), now: { clock.now },
                              isTrackingMenu: trackingMenu)
    }

    /// The quiet period passed: the waiting step runs (`idleDeadline`, with no clock to advance).
    func passIdleMoment(_ warmup: ChromiumWarmup) {
        clock.now += 1
        warmup.idleDeadline()
    }

    @Test func anUnavailableEngineNeverWarms() {
        let warmup = warmup()
        warmup.start(defaultIsChromium: { true })
        warmup.chromiumLikely(.restoredTab)
        #expect(warmup.reason == nil)
        #expect(input.liveSubscriptions == 0, "no wait for an idle moment, no input subscription")
    }

    /// p13-webui-016: a spare window came up while the pages kind has none (`CEFSpareWindow.windowCameUp`
    /// reports `onSpareWindowNeeded`): the next idle moment, never the turn that asked, builds the next
    /// spare with the pages switch read then. Read again at each step: off, the step keeps no pages spare.
    @Test func eachSpareStepRunsAtAnIdleMomentAndReadsThePagesSwitchThen() {
        let engine = FakeWarmupEngine()
        let warmup = warmup(engine: engine)
        let pages = Flag(true)
        warmup.start(defaultIsChromium: { false }, pagesSpare: { pages.value })
        // The browser spare's window came up; the pages spare is missing.
        engine.onSpareWindowNeeded?()
        #expect(engine.prepared.isEmpty, "nothing is built on the turn that asked")
        passIdleMoment(warmup)
        #expect(engine.prepared == [true], "the pages spare is built at the idle moment")

        // A page took it: the next one at the next idle moment, now with pages off.
        pages.value = false
        engine.onSpareWindowNeeded?()
        passIdleMoment(warmup)
        #expect(engine.prepared == [true, false], "pages off: the step keeps no pages spare")
        warmup.stop()
    }

    /// p13-webui-016: `browser.defaultEngine` left Chromium, so pages no longer use it: the untaken
    /// pages spare closes at once; back on Chromium, the next idle moment builds it again. Before
    /// Chromium runs, nothing happens (the first spare step reads the switch itself).
    @Test func thePagesSpareFollowsTheSwitch() {
        let engine = FakeWarmupEngine()
        let warmup = warmup(engine: engine)
        let pages = Flag(true)
        warmup.start(defaultIsChromium: { false }, pagesSpare: { pages.value })

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
        passIdleMoment(warmup)
        #expect(engine.prepared == [true])
        #expect(engine.droppedPages == 1)
        warmup.stop()
    }

    /// p07-memory-047, Chrome's spare rule: a warning holds the spare windows (the untaken one
    /// stays, p13-webui-047) and no spare step runs, neither when one is asked for nor at the next
    /// idle moment; critical keeps the hold and closes the untaken one; back at normal the hold lets
    /// go and the next idle moment, never the level's turn, builds the spare again.
    @Test func noSpareWindowUnderPressureAndNoRefillUntilNormal() {
        let engine = FakeWarmupEngine()
        let memory = ManualMemoryLevelRegistry()
        let warmup = warmup(engine: engine, memory: memory)
        #expect(memory.liveCount == 1, "the spare windows register once")
        #expect(engine.holds.isEmpty, "normal holds nothing")
        warmup.start(defaultIsChromium: { false })
        engine.onSpareWindowNeeded?()
        passIdleMoment(warmup)
        #expect(engine.prepared == [false])

        memory.send(.warning)
        #expect(engine.holds == [true], "a warning holds the spares")
        #expect(engine.closes == 0, "a warning closed the untaken spare")
        #expect(engine.spareWindowCount == 1)
        engine.onSpareWindowNeeded?()
        passIdleMoment(warmup)
        #expect(engine.prepared == [false], "no refill at warning")
        #expect(input.liveSubscriptions == 0, "no idle wait is armed for a spare at warning")

        memory.send(.critical)
        #expect(engine.holds == [true, true], "critical keeps the hold")
        #expect(engine.closes == 1, "critical closes the untaken spare once")
        #expect(engine.spareWindowCount == 0)
        engine.onSpareWindowNeeded?()
        passIdleMoment(warmup)
        #expect(engine.prepared == [false], "no refill at critical")

        memory.send(.normal)
        #expect(engine.holds.last == false, "normal lets the spares go")
        #expect(engine.prepared == [false], "nothing is built on the level's turn")
        passIdleMoment(warmup)
        #expect(engine.prepared == [false, false], "the next idle moment builds the spare again")
        warmup.stop()
    }

    /// Pressure that comes while a spare waits for its idle moment ends the wait in the level's turn,
    /// with its input subscription (no wakeups for a spare that cannot be made), and the moment
    /// builds nothing.
    @Test func pressureDuringTheIdleWaitBuildsNoSpare() {
        let engine = FakeWarmupEngine()
        let memory = ManualMemoryLevelRegistry()
        let warmup = warmup(engine: engine, memory: memory)
        warmup.start(defaultIsChromium: { false })
        engine.onSpareWindowNeeded?()
        #expect(input.liveSubscriptions == 1, "the spare's idle wait hears the tap")
        memory.send(.warning)
        #expect(input.liveSubscriptions == 0, "a warning ends the spare's idle wait and its subscription")
        passIdleMoment(warmup)
        #expect(engine.prepared.isEmpty, "a spare was built at warning")
        warmup.stop()
    }

    /// Pressure ends only a spare's idle wait: a wait for `CefInitialize` (`chromiumLikely`) builds no
    /// spare and goes on.
    @Test func pressureLeavesAWaitThatIsNotASpares() {
        let engine = FakeWarmupEngine()
        let memory = ManualMemoryLevelRegistry()
        let warmup = warmup(engine: engine, memory: memory)
        let ran = Flag(false)
        warmup.waitForIdle { ran.value = true }
        memory.send(.warning)
        #expect(input.liveSubscriptions == 1, "a warning ended a wait that builds no spare")
        passIdleMoment(warmup)
        #expect(ran.value)
        warmup.stop()
    }

    /// A wait for an idle moment hears the input tap (p04-input-012): a key-down, click or left drag
    /// restarts the quiet period, a key-up, button-up or modifier change does not, and the wait's end
    /// drops the subscription.
    @Test func aWaitHearsTheTapUntilItEnds() {
        let warmup = warmup()
        let policy = ChromiumWarmup.Policy()
        warmup.waitForIdle {}
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
        #expect(policy.launchPreloadDelay == .seconds(3))
        #expect(policy.idleInput == .milliseconds(750))
        #expect(policy.maxWait == .seconds(60))
        #expect(policy.recentUse == 7 * 24 * 60 * 60)
    }
}

/// Records the warmup's spare steps; runs nothing.
@MainActor private final class FakeWarmupEngine: ChromiumWarmupEngine {
    var availability: BrowserEngineAvailability = .available
    var isRunning = true
    /// The `pages` argument of each `prepareSpareWindow` call.
    private(set) var prepared: [Bool] = []
    private(set) var droppedPages = 0
    /// The argument of each `holdSpareWindows` call.
    private(set) var holds: [Bool] = []
    /// How many times the untaken spares were closed (`closeUntakenSpareWindows`).
    private(set) var closes = 0
    private(set) var spareWindowCount = 0
    var onSpareWindowNeeded: (@MainActor () -> Void)?

    func usedRecently(within window: TimeInterval) async -> Bool { false }
    func preload() {}
    func libraryLoadEnded() async {}
    func warmStart(reason: String) async {}

    func prepareSpareWindow(pages: Bool) -> Bool {
        prepared.append(pages)
        spareWindowCount = 1
        return true
    }

    func dropPagesSpareWindow() { droppedPages += 1 }

    func holdSpareWindows(_ held: Bool) {
        holds.append(held)
    }

    func closeUntakenSpareWindows() {
        closes += 1
        spareWindowCount = 0
    }
}
