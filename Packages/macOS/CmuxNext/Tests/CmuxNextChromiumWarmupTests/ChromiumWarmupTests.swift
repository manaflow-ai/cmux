import CmuxNextBrowser
@testable import CmuxNextChromiumWarmup
import Foundation
import Testing

/// When the warm start skips, and what counts as an idle moment. An engine
/// with no embedded runtime is unavailable, so nothing here maps or starts
/// Chromium (the runtime is process-wide).
@MainActor struct ChromiumWarmupTests {
    final class Clock { var now: TimeInterval = 100 }

    let clock = Clock()

    func warmup(trackingMenu: @escaping @MainActor () -> Bool = { false }) -> ChromiumWarmup {
        let clock = clock
        return ChromiumWarmup(engine: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()), now: { clock.now }, isTrackingMenu: trackingMenu)
    }

    @Test func anUnavailableEngineNeverWarms() {
        let warmup = warmup()
        warmup.start(defaultIsChromium: { true })
        warmup.chromiumLikely(.restoredTab)
        #expect(warmup.reason == nil)
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
