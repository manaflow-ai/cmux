import Testing
@testable import CmuxFoundation

@Suite struct WindowRecordingSampleScheduleTests {
    @Test func slowWorkSkipsEveryElapsedSlot() {
        let next = WindowRecordingSampleSchedule.nextTargetUptime(
            previousTargetUptime: 0.2,
            interval: 0.1,
            now: 1.05
        )

        #expect(abs(next - 1.1) < 0.000_001)
        #expect(next > 1.05)
    }

    @Test func anOnTimeTargetIsNotSkipped() {
        #expect(WindowRecordingSampleSchedule.nextTargetUptime(
            previousTargetUptime: 4.5,
            interval: 0.25,
            now: 4.5
        ) == 4.5)
    }

    @Test func invalidInputsCannotCreateANonFiniteDeadline() {
        #expect(WindowRecordingSampleSchedule.nextTargetUptime(
            previousTargetUptime: .infinity,
            interval: 0,
            now: 7
        ) == 7)
    }
}
