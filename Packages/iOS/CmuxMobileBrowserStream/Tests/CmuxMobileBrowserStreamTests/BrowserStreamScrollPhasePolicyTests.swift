import CMUXMobileCore
import Testing
@testable import CmuxMobileBrowserStream

@Suite struct BrowserStreamScrollPhasePolicyTests {
    @Test func directGestureTransitionsIntoMomentum() {
        var policy = BrowserStreamScrollPhasePolicy()
        let phases = [
            policy.consume(.trackingBegan),
            policy.consume(.trackingChanged),
            policy.consume(.trackingEnded(willDecelerate: true)),
            policy.consume(.momentumBegan),
            policy.consume(.momentumChanged),
            policy.consume(.momentumEnded),
        ]
        #expect(phases == [.began, .changed, .ended, .momentumBegan, .momentumChanged, .momentumEnded])
    }

    @Test func changedWithoutBeginRepairsPhaseOrdering() {
        var policy = BrowserStreamScrollPhasePolicy()
        let changed = policy.consume(.trackingChanged)
        let cancelled = policy.consume(.cancelled)
        let momentum = policy.consume(.momentumChanged)
        #expect(changed == .began)
        #expect(cancelled == .cancelled)
        #expect(momentum == .momentumBegan)
    }
}
