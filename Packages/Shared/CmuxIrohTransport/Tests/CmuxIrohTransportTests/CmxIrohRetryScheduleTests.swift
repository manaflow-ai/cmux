import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohRetryScheduleTests {
    @Test("invalid schedule inputs normalize to safe positive bounds")
    func invalidInputsNormalize() {
        let schedule = CmxIrohRetrySchedule(
            initialDelay: -1,
            maximumDelay: 0,
            jitterFraction: 2
        )

        #expect(schedule.initialDelay == 1)
        #expect(schedule.maximumDelay == 1)
        #expect(schedule.jitterFraction == 1)
        #expect(schedule.delay(
            failureCount: -1,
            retryAfterSeconds: nil,
            jitterUnitInterval: 2
        ) == 1)
    }

    @Test
    func growsExponentiallyWithPositiveJitterAndCaps() {
        let schedule = CmxIrohRetrySchedule()

        #expect(schedule.delay(
            failureCount: 0,
            retryAfterSeconds: nil,
            jitterUnitInterval: 0
        ) == 30)
        #expect(schedule.delay(
            failureCount: 1,
            retryAfterSeconds: nil,
            jitterUnitInterval: 0
        ) == 60)
        #expect(schedule.delay(
            failureCount: 0,
            retryAfterSeconds: nil,
            jitterUnitInterval: 1
        ) == 37.5)
        #expect(schedule.delay(
            failureCount: 20,
            retryAfterSeconds: nil,
            jitterUnitInterval: 1
        ) == 3_600)
    }

    @Test
    func retryAfterIsAFloorBeforeJitter() {
        let schedule = CmxIrohRetrySchedule()

        #expect(schedule.delay(
            failureCount: 0,
            retryAfterSeconds: 600,
            jitterUnitInterval: 0
        ) == 600)
        #expect(schedule.delay(
            failureCount: 0,
            retryAfterSeconds: 600,
            jitterUnitInterval: 1
        ) == 750)
    }
}
