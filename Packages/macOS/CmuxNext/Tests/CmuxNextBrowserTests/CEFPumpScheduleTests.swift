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

    // An older fork does not ask again when its slice cuts work off.
    @Test func passThatUsedTheTimeSliceRunsAgainWithAnOlderFork() {
        var schedule = CEFPumpSchedule(safetyNet: CEFPumpSchedule.standard)
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

    // A demand-driven fork (API 7) reports "now" itself when its time slice
    // ends with work left, so a long pass alone must not wake the pump.
    @Test func demandOnlyLongPassWaitsForCEF() {
        var schedule = CEFPumpSchedule(safetyNet: .none)
        #expect(begin(&schedule, 10))
        schedule.endWork(now: 10.02, elapsed: 0.02)
        #expect(schedule.nextWake == nil)
    }

    // The fork reports its next delayed task from inside the pass.
    @Test func demandOnlyRequestsInsideAPassAreHonoredAfterIt() {
        var schedule = CEFPumpSchedule(safetyNet: .none)
        #expect(begin(&schedule, 10))
        schedule.request(milliseconds: 200, now: 10.001)
        #expect(schedule.nextWake == nil)
        schedule.endWork(now: 10.002, elapsed: 0.002)
        #expect(abs((schedule.nextWake?.deadline ?? 0) - 10.201) < 1e-9)
        #expect(begin(&schedule, 10.201))
        schedule.request(milliseconds: 0, now: 10.2105)
        schedule.endWork(now: 10.2115, elapsed: 0.0105)
        #expect(schedule.nextWake?.deadline == immediately)
    }

    @Test func demandDrivenForkDropsTheFollowUps() {
        #expect(CEFPumpSchedule.safetyNet(forkAPIVersion: 7) == .none)
        #expect(CEFPumpSchedule.safetyNet(forkAPIVersion: 8) == .none)
        #expect(CEFPumpSchedule.safetyNet(forkAPIVersion: 6) == CEFPumpSchedule.standard)
        #expect(CEFPumpSchedule.safetyNet(forkAPIVersion: 0) == CEFPumpSchedule.standard)
    }
}
