import Foundation
import Testing
@testable import CMUXMobileCore

@Suite("Duration wake tolerance")
struct DurationWakeToleranceTests {
    @Test func aWaitThatIsNotPositiveGetsNoTolerance() {
        #expect(Duration.zero.flexibleWakeTolerance == .zero)
        #expect(Duration.seconds(-3).flexibleWakeTolerance == .zero)
    }

    @Test func aSubSecondWaitGetsChromiumsDefaultLeeway() {
        #expect(Duration.milliseconds(1).flexibleWakeTolerance == .milliseconds(8))
        #expect(Duration.milliseconds(999).flexibleWakeTolerance == .milliseconds(8))
    }

    @Test func aWaitOfASecondOrMoreGetsTenPercentCappedAtOneSecond() {
        #expect(Duration.seconds(1).flexibleWakeTolerance == .milliseconds(100))
        #expect(Duration.seconds(5).flexibleWakeTolerance == .milliseconds(500))
        #expect(Duration.seconds(10).flexibleWakeTolerance == .seconds(1))
        #expect(Duration.seconds(86_400).flexibleWakeTolerance == .seconds(1))
    }

    @Test func theRetryAfterSleepStillWaitsTheWholeDirective() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        try await CmxRetryAfterPolicy.toleratedSleep(seconds: 0.05)
        // A tolerance only lets the wake fire late, never early.
        #expect(clock.now - start >= .milliseconds(50))
    }
}
