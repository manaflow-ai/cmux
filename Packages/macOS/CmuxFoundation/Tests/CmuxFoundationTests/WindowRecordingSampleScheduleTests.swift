import Testing
@testable import CmuxFoundation

@Suite struct WindowRecordingSampleScheduleTests {
    @Test func slowWorkSkipsEveryElapsedSlot() {
        var schedule = WindowRecordingSampleSchedule(firstTargetUptime: 0.2, interval: 0.1)

        let next = schedule.target(atOrAfter: 1.05)

        #expect(abs(next - 1.1) < 0.000_001)
        #expect(next > 1.05)
        #expect(schedule.targetUptime == next)
    }

    @Test func anOnTimeTargetIsNotSkipped() {
        var schedule = WindowRecordingSampleSchedule(firstTargetUptime: 4.5, interval: 0.25)

        #expect(schedule.target(atOrAfter: 4.5) == 4.5)
    }

    @Test func servingASlotStepsToTheNextOne() {
        var schedule = WindowRecordingSampleSchedule(firstTargetUptime: 1, interval: 0.5)

        schedule.advanceOneSlot()

        #expect(schedule.targetUptime == 1.5)
    }

    @Test func invalidInputsCannotCreateANonFiniteDeadline() {
        var schedule = WindowRecordingSampleSchedule(firstTargetUptime: .infinity, interval: 0)

        #expect(schedule.target(atOrAfter: 7) == 7)

        // And a broken interval cannot turn a served slot into a NaN deadline
        // that the sampler would then sleep against.
        schedule.advanceOneSlot()
        #expect(schedule.targetUptime == 7)
    }
}
