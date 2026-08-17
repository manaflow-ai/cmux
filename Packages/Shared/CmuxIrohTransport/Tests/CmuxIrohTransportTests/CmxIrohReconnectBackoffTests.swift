import Foundation
import Testing
@testable import CmuxIrohTransport

struct CmxIrohReconnectBackoffTests {
    @Test
    func sameSeedProducesIdenticalSchedules() {
        let first = CmxIrohReconnectBackoff(seed: 7)
        let second = CmxIrohReconnectBackoff(seed: 7)
        let firstDelays = (0 ..< 64).map { _ in first.nextDelay() }
        let secondDelays = (0 ..< 64).map { _ in second.nextDelay() }
        #expect(firstDelays == secondDelays)
    }

    @Test
    func jitterStaysInsideFloorAndCap() {
        let configuration = CmxIrohReconnectBackoffConfiguration.foreground
        let backoff = CmxIrohReconnectBackoff(
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
        let backoff = CmxIrohReconnectBackoff(seed: 42)
        for _ in 0 ..< 1_000 {
            #expect(backoff.nextDelay()
                <= CmxIrohReconnectBackoffConfiguration.foreground.cap)
        }
    }

    @Test
    func resetReturnsToFloorWindow() {
        let configuration = CmxIrohReconnectBackoffConfiguration.foreground
        let backoff = CmxIrohReconnectBackoff(
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
        let backoff = CmxIrohReconnectBackoff(seed: 9)
        #expect(backoff.nextDelay(retryAfterSeconds: 120) >= 120)
        #expect(backoff.nextDelay(retryAfterSeconds: Int.max)
            <= TimeInterval(CmxIrohBrokerCooldown.maximumRetryAfterSeconds))
        // A server directive never poisons the local streak: the next local
        // draw stays inside the decorrelated window, not the directive's.
        let after = backoff.nextDelay()
        #expect(after <= CmxIrohReconnectBackoffConfiguration.foreground.cap)
    }

    @Test
    func foregroundClientRetryScheduleSharesForegroundBounds() {
        let configuration = CmxIrohReconnectBackoffConfiguration.foreground
        let schedule = CmxIrohRetrySchedule.foregroundClient
        #expect(schedule.initialDelay == configuration.floor)
        #expect(schedule.maximumDelay == configuration.cap)
        // First transient failure retries after about a second, not half a
        // minute, and no locally computed delay can exceed the cap.
        #expect(schedule.delay(
            failureCount: 0,
            retryAfterSeconds: nil,
            jitterUnitInterval: 1
        ) <= configuration.floor * 1.25)
        #expect(schedule.delay(
            failureCount: 20,
            retryAfterSeconds: nil,
            jitterUnitInterval: 1
        ) <= configuration.cap)
    }
}
