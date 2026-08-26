import Foundation
import Testing
@testable import CMUXMobileCore

struct CmxReconnectBackoffTests {
    @Test
    func sameSeedProducesIdenticalSchedules() {
        let first = CmxReconnectBackoff(seed: 7)
        let second = CmxReconnectBackoff(seed: 7)
        let firstDelays = (0 ..< 64).map { _ in first.nextDelay() }
        let secondDelays = (0 ..< 64).map { _ in second.nextDelay() }
        #expect(firstDelays == secondDelays)
    }

    @Test
    func jitterStaysInsideFloorAndCap() {
        let configuration = CmxReconnectBackoffConfiguration.foreground
        let backoff = CmxReconnectBackoff(
            configuration: configuration,
            seed: 0xDECAF
        )
        var upperBound = min(
            configuration.cap,
            configuration.floor * configuration.multiplier
        )
        for _ in 0 ..< 500 {
            let delay = backoff.nextDelay()
            #expect(delay >= configuration.floor)
            #expect(delay <= configuration.cap)
            // Decorrelated jitter: each draw is bounded by the previous
            // delay's growth window, never by unbounded exponentiation.
            #expect(delay <= upperBound)
            upperBound = min(configuration.cap, delay * configuration.multiplier)
        }
    }

    @Test
    func foregroundNeverSchedulesBeyondCapWithoutServerDirective() {
        let backoff = CmxReconnectBackoff(seed: 42)
        for _ in 0 ..< 1_000 {
            #expect(backoff.nextDelay()
                <= CmxReconnectBackoffConfiguration.foreground.cap)
        }
    }

    @Test
    func resetReturnsToFloorWindow() {
        let configuration = CmxReconnectBackoffConfiguration.foreground
        let backoff = CmxReconnectBackoff(
            configuration: configuration,
            seed: 3
        )
        for _ in 0 ..< 32 {
            _ = backoff.nextDelay()
        }
        backoff.reset()
        let afterReset = backoff.nextDelay()
        #expect(afterReset >= configuration.floor)
        #expect(afterReset
            <= min(configuration.cap, configuration.floor * configuration.multiplier))
    }

    @Test
    func serverRetryAfterWinsOverLocalScheduleAndIsBounded() {
        let backoff = CmxReconnectBackoff(seed: 9)
        #expect(backoff.nextDelay(retryAfterSeconds: 120) >= 120)
        #expect(backoff.nextDelay(retryAfterSeconds: Int.max)
            <= TimeInterval(CmxReconnectBackoffConfiguration.maximumServerRetryAfterSeconds))
        // A server directive never poisons the local streak: the next local
        // draw stays inside the decorrelated window, not the directive's.
        let after = backoff.nextDelay()
        #expect(after <= CmxReconnectBackoffConfiguration.foreground.cap)
    }
}
