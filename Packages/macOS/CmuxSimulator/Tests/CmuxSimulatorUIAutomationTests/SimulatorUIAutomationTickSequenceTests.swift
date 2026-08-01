import Testing
@testable import CmuxSimulatorUIAutomation

@MainActor
@Suite("Simulator UI automation tick sequence")
struct SimulatorUIAutomationTickSequenceTests {
    @Test("A zero-length deadline still yields its immediate sample")
    func zeroLengthDeadlineIncludesImmediateSample() async throws {
        let timing = AdvancingSimulatorUIAutomationTiming(nowMilliseconds: 1_000)
        var iterator = SimulatorUIAutomationTickSequence(
            scheduler: timing,
            intervalMilliseconds: 100,
            deadlineMilliseconds: 1_000
        ).makeAsyncIterator()

        #expect(try await iterator.next() == 1_000)
        #expect(try await iterator.next() == nil)
        #expect(timing.sleepCount == 0)
    }

    @Test("The immediate sample survives clock advancement after sequence creation")
    func immediateSampleSurvivesClockAdvancement() async throws {
        let timing = ReadAdvancingSimulatorUIAutomationTiming(
            nowMilliseconds: 1_000,
            advanceMillisecondsPerRead: 1
        )
        var iterator = SimulatorUIAutomationTickSequence(
            scheduler: timing,
            intervalMilliseconds: 100,
            deadlineMilliseconds: 1_000
        ).makeAsyncIterator()

        #expect(try await iterator.next() == 1_001)
        #expect(try await iterator.next() == nil)
        #expect(timing.sleepCount == 0)
    }

    @Test("A wall-clock rollback cannot extend a monotonic deadline")
    func wallClockRollbackDoesNotExtendDeadline() async throws {
        let timing = RollingBackSimulatorUIAutomationTiming(nowMilliseconds: 1_000)
        var iterator = SimulatorUIAutomationTickSequence(
            scheduler: timing,
            intervalMilliseconds: 100,
            deadlineMilliseconds: 1_100,
            includesImmediateEvent: false
        ).makeAsyncIterator()

        #expect(try await iterator.next() == nil)
        #expect(timing.sleepCount == 1)
    }
}
