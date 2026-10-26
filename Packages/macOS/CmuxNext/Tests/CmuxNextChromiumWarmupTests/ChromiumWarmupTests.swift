import CmuxNextBrowser
@testable import CmuxNextChromiumWarmup
import CmuxNextInputCore
import Foundation
import Testing

/// When the warm start skips, and what counts as an idle moment. An engine
/// with no embedded runtime is unavailable, so nothing here maps or starts
/// Chromium (the runtime is process-wide).
@MainActor struct ChromiumWarmupTests {
    final class Clock { var now: TimeInterval = 100 }

    let clock = Clock()
    let input = WarmupFakeInput()

    func warmup(trackingMenu: @escaping @MainActor () -> Bool = { false }) -> ChromiumWarmup {
        let clock = clock
        return ChromiumWarmup(engine: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()), input: input,
                              now: { clock.now }, isTrackingMenu: trackingMenu)
    }

    @Test func anUnavailableEngineNeverWarms() {
        let warmup = warmup()
        warmup.start(defaultIsChromium: { true })
        warmup.chromiumLikely(.restoredTab)
        #expect(warmup.reason == nil)
        #expect(input.subscriptions == 0, "no wait for an idle moment, no input subscription")
    }

    /// The input tap subscription hears what the AppKit monitor's mask did (p04-input-012).
    @Test func theQuietEndsOnTheOldMonitorMask() {
        let types = ChromiumWarmup.quietEndingInput
        for type: InputEventType in [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .scrollWheel, .mouseMoved] {
            #expect(types.contains(type), "\(type)")
        }
        for type: InputEventType in [.keyUp, .flagsChanged, .leftMouseUp, .rightMouseDragged, .otherMouseDragged, .magnify, .swipe] {
            #expect(!types.contains(type), "\(type)")
        }
        #expect(types.classes == [.key, .button, .drag, .scroll, .pointerMove])
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

/// An ``InputObserving`` that counts subscriptions (an unavailable engine never waits for input).
@MainActor final class WarmupFakeInput: InputObserving {
    private var flags: [InputSubscriptionFlag] = []
    var lastDispatched: InputEventRecord?
    var lastPointer: InputEventRecord?

    func observe(_ classes: InputEventClasses, windowNumber: Int?,
                 _ handler: @escaping @MainActor (InputEventRecord) -> Void) -> InputSubscription {
        let flag = InputSubscriptionFlag()
        flags.append(flag)
        return InputSubscription(flag: flag)
    }

    /// The subscriptions not cancelled or released.
    var subscriptions: Int { flags.count(where: { !$0.isCancelled }) }
}
