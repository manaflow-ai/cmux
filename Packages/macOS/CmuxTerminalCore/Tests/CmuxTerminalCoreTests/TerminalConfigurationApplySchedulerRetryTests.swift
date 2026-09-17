import Testing
@testable import CmuxTerminalCore

private typealias Snapshot = TerminalConfigurationApplySchedulerTestSnapshot

@Suite("Terminal configuration apply scheduler retries")
struct TerminalConfigurationApplySchedulerRetryTests {
    @Test @MainActor
    func retriesInLaterTurnsAndAbandonsAtTheConfiguredLimit() {
        let manualScheduler = ManualConfigurationApplyScheduler()
        let scheduler = TerminalConfigurationApplyScheduler<Int, Snapshot>(
            maximumVisitsPerDrain: 1,
            maximumAttemptsPerID: 2,
            schedule: manualScheduler.schedule
        )
        let snapshot = Snapshot(id: 9)
        var source = [1].makeIterator()
        var attemptCount = 0
        var abandonedIDs: [Int] = []
        var abandonReasons: [TerminalConfigurationApplyAbandonReason] = []
        var didFinish = false

        scheduler.replacePendingWork(
            snapshot: snapshot,
            prioritizedIDs: [],
            nextID: {
                guard let id = source.next() else { return .exhausted }
                return .id(id)
            },
            apply: { _, _ in
                attemptCount += 1
                return .retry
            },
            abandon: { id, _, reason in
                abandonedIDs.append(id)
                abandonReasons.append(reason)
            },
            completion: {
                didFinish = true
            }
        )
        while manualScheduler.pendingCount > 0 {
            manualScheduler.fireNext()
        }

        #expect(attemptCount == 2)
        #expect(abandonedIDs == [1])
        #expect(abandonReasons == [.retryLimitReached])
        #expect(didFinish)
    }
}
