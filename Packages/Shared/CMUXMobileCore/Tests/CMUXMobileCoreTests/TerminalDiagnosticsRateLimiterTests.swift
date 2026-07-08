import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct TerminalDiagnosticsRateLimiterTests {
    @Test func capsEventsPerKeyWithinWindow() {
        let start = Date(timeIntervalSince1970: 100)
        var limiter = TerminalDiagnosticsRateLimiter(maxEventsPerWindow: 2, window: 30)

        let first = limiter.shouldAllow(key: "event", now: start)
        let second = limiter.shouldAllow(key: "event", now: start.addingTimeInterval(1))
        let capped = limiter.shouldAllow(key: "event", now: start.addingTimeInterval(2))
        let other = limiter.shouldAllow(key: "other", now: start.addingTimeInterval(2))
        let reset = limiter.shouldAllow(key: "event", now: start.addingTimeInterval(31))
        #expect(first)
        #expect(second)
        #expect(!capped)
        #expect(other)
        #expect(reset)
    }

    @Test func enforcesMinimumInterval() {
        let start = Date(timeIntervalSince1970: 200)
        var limiter = TerminalDiagnosticsRateLimiter(
            maxEventsPerWindow: 10,
            window: 60,
            minimumInterval: 5
        )

        let first = limiter.shouldAllow(key: "probe", now: start)
        let tooSoon = limiter.shouldAllow(key: "probe", now: start.addingTimeInterval(4.9))
        let spaced = limiter.shouldAllow(key: "probe", now: start.addingTimeInterval(5))
        #expect(first)
        #expect(!tooSoon)
        #expect(spaced)
    }

    @Test func samplesFirstAndEveryThirtySecondFrameDrop() {
        #expect(TerminalDiagnosticsRateLimiter.shouldSampleFrameDrop(count: 1))
        #expect(!TerminalDiagnosticsRateLimiter.shouldSampleFrameDrop(count: 2))
        #expect(!TerminalDiagnosticsRateLimiter.shouldSampleFrameDrop(count: 31))
        #expect(TerminalDiagnosticsRateLimiter.shouldSampleFrameDrop(count: 32))
        #expect(TerminalDiagnosticsRateLimiter.shouldSampleFrameDrop(count: 64))
    }
}
