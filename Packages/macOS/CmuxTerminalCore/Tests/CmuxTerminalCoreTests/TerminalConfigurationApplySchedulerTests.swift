import Testing
@testable import CmuxTerminalCore

@Suite("Terminal configuration apply scheduler")
struct TerminalConfigurationApplySchedulerTests {
    @Test @MainActor
    func boundsImmediatePriorityBeforeYielding() {
        let manualScheduler = ManualConfigurationApplyScheduler()
        let scheduler = TerminalConfigurationApplyScheduler<Int, Snapshot>(
            maximumVisitsPerDrain: 2,
            schedule: manualScheduler.schedule
        )
        let snapshot = Snapshot(id: 8)
        var applied: [Int] = []
        var didFinish = false

        scheduler.replacePendingWork(
            snapshot: snapshot,
            prioritizedIDs: [1, 2, 3, 4],
            nextID: { .exhausted },
            apply: { id, _ in
                applied.append(id)
                return .complete
            },
            completion: {
                didFinish = true
            }
        )

        #expect(applied == [1, 2])
        #expect(manualScheduler.pendingCount == 1)
        #expect(!didFinish)

        while manualScheduler.pendingCount > 0 {
            manualScheduler.fireNext()
        }

        #expect(applied == [1, 2, 3, 4])
        #expect(didFinish)
    }

    @Test @MainActor
    func skippedTraversalEntriesConsumeTheDeferredTurnBudget() {
        let manualScheduler = ManualConfigurationApplyScheduler()
        let scheduler = TerminalConfigurationApplyScheduler<Int, Snapshot>(
            maximumVisitsPerDrain: 2,
            schedule: manualScheduler.schedule
        )
        let snapshot = Snapshot(id: 10)
        var source = [
            TerminalConfigurationApplyScheduler<Int, Snapshot>.NextIDResult.skipped,
            .skipped,
            .id(9),
            .exhausted,
        ].makeIterator()
        var applied: [Int] = []

        scheduler.replacePendingWork(
            snapshot: snapshot,
            prioritizedIDs: [],
            nextID: { source.next() ?? .exhausted },
            apply: { id, _ in
                applied.append(id)
                return .complete
            }
        )

        #expect(manualScheduler.pendingCount == 1)
        manualScheduler.fireNext()
        #expect(applied.isEmpty)
        #expect(manualScheduler.pendingCount == 1)

        manualScheduler.fireNext()
        #expect(applied == [9])
        #expect(manualScheduler.pendingCount == 0)
    }

    @Test @MainActor
    func retriesAddedDuringADrainYieldBeforeTheirNextAttempt() {
        let manualScheduler = ManualConfigurationApplyScheduler()
        let scheduler = TerminalConfigurationApplyScheduler<Int, Snapshot>(
            maximumVisitsPerDrain: 3,
            maximumAttemptsPerID: 2,
            schedule: manualScheduler.schedule
        )
        let snapshot = Snapshot(id: 11)
        var source = [
            TerminalConfigurationApplyScheduler<Int, Snapshot>.NextIDResult.id(1),
            .exhausted,
        ].makeIterator()
        var attemptCount = 0

        scheduler.replacePendingWork(
            snapshot: snapshot,
            prioritizedIDs: [],
            nextID: { source.next() ?? .exhausted },
            apply: { _, _ in
                attemptCount += 1
                return attemptCount == 1 ? .retry : .complete
            }
        )

        manualScheduler.fireNext()
        #expect(attemptCount == 1)
        #expect(manualScheduler.pendingCount == 1)

        manualScheduler.fireNext()
        #expect(attemptCount == 2)
        #expect(manualScheduler.pendingCount == 0)
    }

    @Test @MainActor
    func cancelPendingWorkAbandonsRetriesAndInvalidatesScheduledDrain() {
        let manualScheduler = ManualConfigurationApplyScheduler()
        let scheduler = TerminalConfigurationApplyScheduler<Int, Snapshot>(
            maximumVisitsPerDrain: 1,
            schedule: manualScheduler.schedule
        )
        let snapshot = Snapshot(id: 12)
        var events: [String] = []
        var didFinish = false

        scheduler.replacePendingWork(
            snapshot: snapshot,
            prioritizedIDs: [1],
            nextID: { .exhausted },
            apply: { id, _ in
                events.append("apply:\(id)")
                return .retry
            },
            abandon: { id, _, reason in
                #expect(reason == .pendingWorkReplaced)
                events.append("abandon:\(id)")
            },
            completion: {
                didFinish = true
            }
        )

        scheduler.cancelPendingWork()

        #expect(events == ["apply:1", "abandon:1"])
        #expect(didFinish)
        #expect(!scheduler.hasPendingWork)

        // The already queued old turn must not touch the canceled snapshot.
        manualScheduler.fireNext()
        #expect(events == ["apply:1", "abandon:1"])
    }

    @Test @MainActor
    func appliesEveryVisibleSurfaceImmediatelyAndBoundsDeferredDrainTurns() {
        let manualScheduler = ManualConfigurationApplyScheduler()
        let scheduler = TerminalConfigurationApplyScheduler<Int, Snapshot>(
            maximumVisitsPerDrain: 3,
            schedule: manualScheduler.schedule
        )
        let snapshot = Snapshot(id: 7)
        var source = [0, 1, 2, 3, 4, 5].makeIterator()
        var applied: [Int] = []
        var didFinish = false

        scheduler.replacePendingWork(
            snapshot: snapshot,
            prioritizedIDs: [3, 1],
            nextID: {
                guard let id = source.next() else { return .exhausted }
                return .id(id)
            },
            apply: { id, receivedSnapshot in
                #expect(receivedSnapshot === snapshot)
                applied.append(id)
                return .complete
            },
            completion: {
                didFinish = true
            }
        )

        #expect(applied == [3, 1])
        #expect(manualScheduler.pendingCount == 1)
        #expect(!didFinish)

        while manualScheduler.pendingCount > 0 {
            let countBeforeTurn = applied.count
            manualScheduler.fireNext()
            #expect(applied.count - countBeforeTurn <= 3)
        }

        #expect(applied == [3, 1, 0, 2, 4, 5])
        #expect(didFinish)
    }

    @Test @MainActor
    func newerSnapshotSupersedesUndrainedWorkWithoutSchedulingASecondTurn() {
        let manualScheduler = ManualConfigurationApplyScheduler()
        let scheduler = TerminalConfigurationApplyScheduler<Int, Snapshot>(
            maximumVisitsPerDrain: 4,
            schedule: manualScheduler.schedule
        )
        let firstSnapshot = Snapshot(id: 1)
        let secondSnapshot = Snapshot(id: 2)
        var firstSource = [11, 12].makeIterator()
        var secondSource = [21].makeIterator()
        var applied: [(id: Int, snapshotID: Int)] = []
        var completedSnapshotIDs: [Int] = []

        scheduler.replacePendingWork(
            snapshot: firstSnapshot,
            prioritizedIDs: [],
            nextID: {
                guard let id = firstSource.next() else { return .exhausted }
                return .id(id)
            },
            apply: { id, snapshot in
                applied.append((id, snapshot.id))
                return .complete
            },
            completion: {
                completedSnapshotIDs.append(firstSnapshot.id)
            }
        )
        scheduler.replacePendingWork(
            snapshot: secondSnapshot,
            prioritizedIDs: [20],
            nextID: {
                guard let id = secondSource.next() else { return .exhausted }
                return .id(id)
            },
            apply: { id, snapshot in
                applied.append((id, snapshot.id))
                return .complete
            },
            completion: {
                completedSnapshotIDs.append(secondSnapshot.id)
            }
        )

        #expect(manualScheduler.pendingCount == 1)
        manualScheduler.fireNext()

        #expect(applied.map(\.id) == [20, 21])
        #expect(applied.map(\.snapshotID) == [2, 2])
        #expect(completedSnapshotIDs == [2])
        #expect(manualScheduler.pendingCount == 0)
    }

    @Test @MainActor
    func replacingRetryingSnapshotRollsBackBeforeApplyingNewWork() {
        let manualScheduler = ManualConfigurationApplyScheduler()
        let scheduler = TerminalConfigurationApplyScheduler<Int, Snapshot>(
            maximumVisitsPerDrain: 1,
            schedule: manualScheduler.schedule
        )
        let firstSnapshot = Snapshot(id: 1)
        let secondSnapshot = Snapshot(id: 2)
        var events: [String] = []

        scheduler.replacePendingWork(
            snapshot: firstSnapshot,
            prioritizedIDs: [11],
            nextID: { .exhausted },
            apply: { id, snapshot in
                events.append("apply:\(id):\(snapshot.id)")
                return .retry
            },
            abandon: { id, snapshot, reason in
                #expect(reason == .pendingWorkReplaced)
                events.append("abandon:\(id):\(snapshot.id)")
            }
        )
        scheduler.replacePendingWork(
            snapshot: secondSnapshot,
            prioritizedIDs: [22],
            nextID: { .exhausted },
            apply: { id, snapshot in
                events.append("apply:\(id):\(snapshot.id)")
                return .complete
            }
        )

        #expect(
            events == [
                "apply:11:1",
                "abandon:11:1",
                "apply:22:2",
            ]
        )
        #expect(manualScheduler.pendingCount == 1)
    }

    @Test @MainActor
    func sharesOneDerivedSnapshotAcrossEverySurface() {
        let manualScheduler = ManualConfigurationApplyScheduler()
        let scheduler = TerminalConfigurationApplyScheduler<Int, Snapshot>(
            maximumVisitsPerDrain: 2,
            schedule: manualScheduler.schedule
        )
        var derivationCount = 0
        let snapshot: Snapshot = {
            derivationCount += 1
            return Snapshot(id: 42)
        }()
        var source = [2, 3].makeIterator()
        var receivedSnapshots: [Snapshot] = []

        scheduler.replacePendingWork(
            snapshot: snapshot,
            prioritizedIDs: [1],
            nextID: {
                guard let id = source.next() else { return .exhausted }
                return .id(id)
            },
            apply: { _, receivedSnapshot in
                receivedSnapshots.append(receivedSnapshot)
                return .complete
            }
        )
        while manualScheduler.pendingCount > 0 {
            manualScheduler.fireNext()
        }

        #expect(derivationCount == 1)
        #expect(receivedSnapshots.count == 3)
        #expect(receivedSnapshots.allSatisfy { $0 === snapshot })
    }

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

private final class Snapshot {
    let id: Int

    init(id: Int) {
        self.id = id
    }
}

@MainActor
private final class ManualConfigurationApplyScheduler {
    typealias Action = @MainActor @Sendable () -> Void

    private var pending: [Action] = []

    var pendingCount: Int {
        pending.count
    }

    func schedule(_ action: @escaping Action) {
        pending.append(action)
    }

    func fireNext() {
        guard !pending.isEmpty else {
            Issue.record("Expected a scheduled configuration apply turn")
            return
        }
        pending.removeFirst()()
    }
}
