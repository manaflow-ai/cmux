import Foundation
import Testing
@testable import CmuxNextBrowser

private func begin(_ schedule: inout CEFPumpSchedule, _ now: TimeInterval) -> Bool {
    schedule.beginWork(now: now)
}

private let immediately = -TimeInterval.infinity

@Suite struct CEFPumpScheduleTests {
    @Test func demandOnlyScheduleIsIdleWithoutRequests() {
        var schedule = CEFPumpSchedule(safetyNet: .none)
        #expect(schedule.nextWake == nil)
        schedule.request(milliseconds: 0, now: 10)
        #expect(schedule.nextWake?.deadline == immediately)
        #expect(begin(&schedule, 10))
        schedule.endWork(now: 10.001, elapsed: 0.001)
        #expect(schedule.nextWake == nil)
    }

    @Test func delayedRequestSetsTheDeadlineAndIsServedWhenDue() {
        var schedule = CEFPumpSchedule(safetyNet: .none)
        schedule.request(milliseconds: 250, now: 10)
        #expect(schedule.nextWake == .init(deadline: 10.25, tolerance: 0))
        schedule.request(milliseconds: 900, now: 10)
        #expect(schedule.nextWake == .init(deadline: 10.9, tolerance: 0))
        #expect(begin(&schedule, 10.9))
        schedule.endWork(now: 10.9005, elapsed: 0.0005)
        #expect(schedule.nextWake == nil)
    }

    @Test func earlyPassKeepsAFutureDelayedRequest() {
        var schedule = CEFPumpSchedule(safetyNet: .none)
        schedule.request(milliseconds: 500, now: 10)
        schedule.request(milliseconds: 0, now: 10)
        #expect(begin(&schedule, 10))
        schedule.endWork(now: 10.001, elapsed: 0.001)
        #expect(schedule.nextWake == .init(deadline: 10.5, tolerance: 0))
    }

    @Test func nestedPassIsRefusedAndRunsAfterTheOuterOne() {
        var schedule = CEFPumpSchedule(safetyNet: .none)
        #expect(begin(&schedule, 10))
        #expect(!begin(&schedule, 10.01))
        #expect(schedule.nextWake == nil)
        schedule.endWork(now: 10.002, elapsed: 0.002)
        #expect(schedule.nextWake?.deadline == immediately)
    }

    @Test func passThatUsedTheTimeSliceRunsAgain() {
        var schedule = CEFPumpSchedule(safetyNet: .none)
        #expect(begin(&schedule, 10))
        schedule.endWork(now: 10.0101, elapsed: CEFPumpSchedule.timeSlice + 0.0001)
        #expect(schedule.nextWake?.deadline == immediately)
    }

    @Test func delayedRequestReplacesThePendingSafetyNet() {
        var schedule = CEFPumpSchedule()
        #expect(begin(&schedule, 10))
        schedule.endWork(now: 10, elapsed: 0)
        let net = schedule.nextWake
        #expect(abs((net?.deadline ?? 0) - (10 + 1.0 / 30)) < 1e-9)
        #expect(abs((net?.tolerance ?? 0) - 0.1 / 30) < 1e-9)
        // CEF reports its earliest delayed task, which covers what the
        // safety net guessed.
        schedule.request(milliseconds: 3_000, now: 10.01)
        #expect(abs((schedule.nextWake?.deadline ?? 0) - 13.01) < 1e-9)
        #expect(schedule.nextWake?.tolerance == 0)
    }
}
