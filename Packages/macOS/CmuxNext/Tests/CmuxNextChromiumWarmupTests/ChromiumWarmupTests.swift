import CmuxNextBrowser
@testable import CmuxNextChromiumWarmup
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// When the warm start skips, and what counts as an idle moment. An engine
/// with no embedded runtime is unavailable, so nothing here maps or starts
/// Chromium (the runtime is process-wide).
@MainActor struct ChromiumWarmupTests {
    final class Clock { var now: TimeInterval = 100 }

    let clock = Clock()
    let input = FakeInputTap()

    func warmup(trackingMenu: @escaping @MainActor () -> Bool = { false }) -> ChromiumWarmup {
        let clock = clock
        // A manual clock nobody advances: no deadline fires, so a test's wait ends only when it says.
        return ChromiumWarmup(engine: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()), input: input,
                              clock: ManualClock(), now: { clock.now }, isTrackingMenu: trackingMenu)
    }

    @Test func anUnavailableEngineNeverWarms() {
        let warmup = warmup()
        warmup.start(defaultIsChromium: { true })
        warmup.chromiumLikely(.restoredTab)
        #expect(warmup.reason == nil)
        #expect(input.liveSubscriptions == 0, "no wait for an idle moment, no input subscription")
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
