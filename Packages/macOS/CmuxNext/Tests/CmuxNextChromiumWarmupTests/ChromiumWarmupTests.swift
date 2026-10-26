import CmuxNextBrowser
@testable import CmuxNextChromiumWarmup
import CmuxNextCompat
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// When the warm start skips, what counts as an idle moment, and how its steps ride the launch's
/// scheduler (p08-startup-018): never before `startup_complete`, never with input pending, and no
/// ChromiumWarmup timer during launch. An engine with no embedded runtime is unavailable, so nothing
/// here maps or starts Chromium (the runtime is process-wide); the step tests ask for a step directly.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ChromiumWarmupTests {
    final class Clock { var now: TimeInterval = 100 }

    let clock = Clock()
    let input = FakeInputTap()

    func warmup(trackingMenu: @escaping @MainActor () -> Bool = { false }) -> ChromiumWarmup {
        let clock = clock
        // A manual clock nobody advances: no deadline fires, so a test fires one by hand (`idleDeadline`).
        return ChromiumWarmup(engine: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()), input: input,
                              clock: ManualClock(), now: { clock.now }, isTrackingMenu: trackingMenu)
    }

    @Test func anUnavailableEngineNeverWarms() {
        let launch = WarmupLaunch()
        let warmup = warmup()
        warmup.attach(launch.startup)
        warmup.start(defaultIsChromium: { true })
        warmup.chromiumLikely(.restoredTab)
        launch.complete()
        launch.fire()
        #expect(warmup.reason == nil)
        #expect(input.liveSubscriptions == 0, "no wait for an idle moment, no input subscription")
        #expect(launch.startup.log.records.isEmpty, "nothing posted")
    }

    /// A hidden need (a restored Chromium tab that does not show) never starts Chromium during launch:
    /// the step is held until `startup_complete`, and no ChromiumWarmup timer is armed meanwhile.
    @Test func aStepNeverRunsBeforeStartupComplete() {
        let launch = WarmupLaunch()
        let warmup = warmup()
        warmup.attach(launch.startup)
        var ran = 0
        warmup.request("ChromiumWarmup.cefInitialize") { ran += 1 }
        clock.now += 5
        launch.startup.firstFrameCommitted()
        for _ in 0..<4 { launch.fire() }
        #expect(ran == 0, "held until startup completes")
        #expect(!warmup.idleTimerArmed, "no launch timer")
        launch.complete()
        launch.fire()
        #expect(ran == 1, "the first idle frame after startup_complete")
        #expect(!warmup.idleTimerArmed)
        #expect(input.liveSubscriptions == 0, "the step's end drops the subscription")
        #expect(launch.startup.log.records.map(\.name.description) == ["ChromiumWarmup.cefInitialize"])
        #expect(launch.startup.log.records.allSatisfy { $0.priority == .afterStartup && $0.destination == .main })
    }

    /// A signal before the scheduler is attached is posted at the attach, still afterStartup.
    @Test func aStepAskedBeforeAttachIsPostedThere() {
        let launch = WarmupLaunch()
        let warmup = warmup()
        var ran = 0
        warmup.request("ChromiumWarmup.spareWindow") { ran += 1 }
        clock.now += 1
        launch.fire()
        #expect(ran == 0)
        warmup.attach(launch.startup)
        launch.fire()
        #expect(ran == 0, "startup has not completed")
        launch.complete()
        launch.fire()
        #expect(ran == 1)
    }

    @Test func aStepNeverRunsWithInputPending() {
        let launch = WarmupLaunch()
        launch.complete()
        let warmup = warmup()
        warmup.attach(launch.startup)
        var ran = 0
        warmup.request("ChromiumWarmup.cefInitialize") { ran += 1 }
        clock.now += 1
        launch.input.pending = true
        launch.fire()
        #expect(ran == 0, "a pending key goes first")
        launch.input.pending = false
        launch.fire()
        #expect(ran == 1)
    }

    /// An idle app pays no wakeup: the post finds the quiet period passed and runs the step.
    @Test func noInputMeansNoTimer() {
        let launch = WarmupLaunch()
        launch.complete()
        let warmup = warmup()
        warmup.attach(launch.startup)
        var ran = 0
        warmup.request("ChromiumWarmup.spareWindow") { ran += 1 }
        #expect(!warmup.idleTimerArmed)
        clock.now += 1
        launch.fire()
        #expect(ran == 1)
        #expect(!warmup.idleTimerArmed)
    }

    /// Input while the step is pending arms the one idle timer for the rest of the quiet period;
    /// the deadline posts the step again and the post cancels the timer.
    @Test func inputArmsTheOneTimerAndThePostCancelsIt() {
        let launch = WarmupLaunch()
        launch.complete()
        let warmup = warmup()
        warmup.attach(launch.startup)
        var ran = 0
        warmup.request("ChromiumWarmup.cefInitialize") { ran += 1 }
        clock.now += 0.5
        input.deliver(InputEventRecord(type: .keyDown, timestamp: 1))
        launch.fire()
        #expect(ran == 0, "a key came within the quiet period")
        #expect(warmup.idleTimerArmed, "armed after input")
        clock.now += 0.3
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
        let launch = WarmupLaunch()
        launch.complete()
        var tracking = false
        let warmup = warmup(trackingMenu: { tracking })
        warmup.attach(launch.startup)
        var ran = 0
        warmup.request("ChromiumWarmup.spareWindow") { ran += 1 }
        clock.now += 1
        tracking = true
        launch.fire()
        #expect(ran == 0)
        #expect(!warmup.idleTimerArmed, "no timer while a menu tracks")
        tracking = false
        warmup.menuTrackingEnded()
        #expect(warmup.idleTimerArmed, "one quiet period after the menu")
        clock.now += 0.75
        warmup.idleDeadline()
        launch.fire()
        #expect(ran == 1)
    }

    /// An app that is never idle for `maxWait` gives the step up: no timer, no subscription.
    @Test func aStepIsGivenUpAfterMaxWait() {
        let launch = WarmupLaunch()
        launch.complete()
        let warmup = warmup()
        warmup.attach(launch.startup)
        var ran = 0
        warmup.request("ChromiumWarmup.cefInitialize") { ran += 1 }
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

/// A launch's scheduler on hand-fired frames and a hand-run main hop (StartupSchedulerTests' fixture).
@MainActor
private final class WarmupLaunch {
    let input: WarmupPendingInput
    let hand: WarmupHandHop
    let uptime: WarmupUptime
    let mainWork: MainWorkScheduler
    let startup: StartupScheduler
    private var timestamp = 0.0

    init() {
        let input = WarmupPendingInput()
        let hand = WarmupHandHop()
        let uptime = WarmupUptime()
        let budget = MainFrameBudget(input: input, uptimeNanos: { uptime.now })
        let mainWork = MainWorkScheduler.testing(budget: budget, clock: ManualClock(), ledger: WakeupLedger()) { _ in WarmupLink() }
        (self.input, self.hand, self.uptime, self.mainWork) = (input, hand, uptime, mainWork)
        startup = StartupScheduler(mainWork: mainWork, background: BackgroundWork(label: "test.chromium-warmup"), hop: hand.hop,
                                   clock: ManualClock(), ledger: WakeupLedger(), criticalAllowlist: [], log: StartupTaskLog())
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

/// A main hop the test runs by hand.
private final class WarmupHandHop: Sendable {
    private let queued = Mutex<[@MainActor @Sendable () -> Void]>([])

    var hop: StartupMainHop {
        StartupMainHop { [self] work in queued.withLock { $0.append(work) } }
    }

    /// Runs every queued hop, and the hops they queue.
    @MainActor func drain() {
        while true {
            let batch = queued.withLock { queued -> [@MainActor @Sendable () -> Void] in
                defer { queued = [] }
                return queued
            }
            if batch.isEmpty { return }
            for work in batch { work() }
        }
    }
}

private final class WarmupUptime {
    var now: UInt64 = 1_000_000_000
}

@MainActor
private final class WarmupPendingInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

private final class WarmupLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
