import CmuxNextBrowser
import Foundation
import Testing
@testable import CmuxNextApp

@MainActor
@Suite struct ChromiumWarmupTests {
    final class Clock {
        var now: TimeInterval = 100
        var tracking = false
    }

    func warmup(_ clock: Clock, engine: CEFEngine = CEFEngine(layout: nil)) -> ChromiumWarmup {
        ChromiumWarmup(engine: engine, sleep: { _ in }, now: { clock.now }, isTrackingMenu: { clock.tracking })
    }

    @Test func idleNeedsQuietInputAndNoMenuTracking() {
        let clock = Clock()
        let subject = warmup(clock)
        let policy = ChromiumWarmup.Policy(idleInput: .milliseconds(750))
        subject.noteInput()
        clock.now += 0.5
        #expect(!subject.isIdle(policy))
        clock.now += 0.3
        #expect(subject.isIdle(policy))
        clock.tracking = true
        #expect(!subject.isIdle(policy))
        clock.tracking = false
        subject.noteInput()
        #expect(!subject.isIdle(policy))
    }

    @Test func withoutARuntimeNothingIsPredictedOrLoaded() {
        let clock = Clock()
        let engine = CEFEngine(layout: nil)
        let subject = warmup(clock, engine: engine)
        subject.start()
        subject.chromiumLikely(.newTabMenu)
        #expect(subject.reason == nil)
        #expect(!engine.startReport.preloaded)
    }
}
