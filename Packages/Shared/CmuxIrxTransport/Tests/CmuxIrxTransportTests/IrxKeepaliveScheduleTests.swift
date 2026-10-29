import Testing
@testable import CmuxIrxTransport

struct IrxKeepaliveScheduleTests {
    private let schedule = IrxKeepaliveSchedule(interval: .seconds(5))
    private let start = ContinuousClock.now

    @Test func aQuietLinkProbesOneIntervalAfterTheLastProbe() {
        #expect(schedule.nextProbe(afterProbe: start, lastInbound: nil) == start + .seconds(5))
    }

    @Test func bytesBeforeTheLastProbeDoNotMoveIt() {
        let due = schedule.nextProbe(afterProbe: start, lastInbound: start - .seconds(3))
        #expect(due == start + .seconds(5))
    }

    @Test func bytesAfterTheLastProbePushTheNextOneOut() {
        let due = schedule.nextProbe(afterProbe: start, lastInbound: start + .seconds(4))
        #expect(due == start + .seconds(9))
    }
}
