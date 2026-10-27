import CmuxNextCompat
import Testing

/// Mutex lock ranks (plans/cmux-next/chrome-parity/p10-stability.md, task 148): a thread takes ranked mutexes in
/// ascending order; in Debug an inversion stops the process before it waits and names both locks. Trap cases
/// run in a child process (exit tests).
@Suite struct MutexRankTests {
    // MARK: the order rule

    @Test func aRankAfterEveryHeldRankKeepsTheOrder() {
        let outer = MutexRank("test.outer", order: 1)
        let middle = MutexRank("test.middle", order: 2)
        let inner = MutexRank("test.inner", order: 3)
        #expect(inner.inversion(holding: [outer, middle]) == nil)
        #expect(outer.inversion(holding: []) == nil)
    }

    @Test func aRankAtOrBeforeAHeldRankInvertsTheHighestHeld() {
        let outer = MutexRank("test.outer", order: 1)
        let middle = MutexRank("test.middle", order: 2)
        let inner = MutexRank("test.inner", order: 3)
        #expect(outer.inversion(holding: [middle, inner])?.order == 3)
        #expect(middle.inversion(holding: [middle])?.order == 2)
        // A try-lock is recorded out of order: the check scans every held rank, not only the last.
        #expect(middle.inversion(holding: [inner, outer])?.order == 3)
    }

    @Test func twoLeafLocksNeverNest() {
        let first = MutexRank.leaf("test.leaf-a")
        #expect(MutexRank.leaf("test.leaf-b").inversion(holding: [first]) != nil)
        #expect(first.inversion(holding: [MutexRank("test.ranked", order: 7)]) == nil)
    }

    @Test func theInversionMessageNamesBothLocks() {
        let message = MutexRank("test.outer", order: 1).inversionMessage(holding: MutexRank("test.inner", order: 3))
        #expect(message.contains("acquiring test.outer (rank 1)"))
        #expect(message.contains("holds test.inner (rank 3)"))
    }

    // MARK: the table matches the nesting the code does

    @Test func cmuxNextRanksOrderEachLockBeforeTheLockItTakes() {
        #expect(MutexRank.daemonLineTransportSocket.order < MutexRank.daemonLineTransportState.order)
        #expect(MutexRank.daemonTerminalAttachmentControl.order < MutexRank.daemonTerminalEventQueue.order)
        #expect(MutexRank.terminalInputRingBacklog.order < MutexRank.terminalInputRingSlot.order)
        let leaves: [MutexRank] = [
            .terminalInputLaneOverflow, .terminalOutputLaneBacklog,
            .crashReporterSentryHandlers, .lagSpikeLimiter, .lagSpikeContextProvider,
        ]
        #expect(leaves.allSatisfy { $0.order == MutexRank.leafOrder })
    }

    // MARK: mutexes in order (no trap)

    @Test func nestedMutexesInAscendingOrderRunAndReleaseTheirRanks() {
        let outer = Mutex(0, rank: MutexRank("test.outer", order: 1))
        let inner = Mutex(0, rank: MutexRank("test.inner", order: 2))
        outer.withLock { count in
            inner.withLock { $0 += 1 }
            count += 1
        }
        // Released: the lower rank may be taken again after the higher one, one at a time.
        inner.withLock { $0 += 1 }
        outer.withLock { $0 += 1 }
        #expect(outer.withLock { $0 } == 2)
        #expect(inner.withLock { $0 } == 2)
    }

    @Test func aTryLockOutOfOrderIsNotChecked() {
        let outer = Mutex(0, rank: MutexRank("test.outer", order: 1))
        let inner = Mutex(0, rank: MutexRank("test.inner", order: 2))
        let ran = inner.withLock { _ in outer.withLockIfAvailable { $0 += 1 } }
        #expect(ran != nil)
    }

    @Test func anUnrankedMutexIsNeverChecked() {
        let ranked = Mutex(0, rank: .leaf("test.leaf"))
        let unranked = Mutex(0)
        ranked.withLock { _ in unranked.withLock { $0 += 1 } }
        unranked.withLock { _ in ranked.withLock { $0 += 1 } }
        #expect(unranked.withLock { $0 } == 1)
    }

    // MARK: an inversion stops the process (Debug)

    #if DEBUG
    @Test func takingALowerRankInsideAHigherOneStopsTheProcessNamingBothLocks() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let outer = Mutex(0, rank: MutexRank("test.outer", order: 1))
            let inner = Mutex(0, rank: MutexRank("test.inner", order: 2))
            inner.withLock { _ in outer.withLock { $0 += 1 } }
        }
        let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(stderr.contains("acquiring test.outer (rank 1) while this thread holds test.inner (rank 2)"))
    }

    @Test func nestingTwoLocksAtTheSameRankStopsTheProcess() async {
        await #expect(processExitsWith: .failure) {
            let first = Mutex(0, rank: .leaf("test.leaf-a"))
            let second = Mutex(0, rank: .leaf("test.leaf-b"))
            first.withLock { _ in second.withLock { $0 += 1 } }
        }
    }

    @Test func aTryLockIsRecordedSoALowerWaitAfterItStopsTheProcess() async {
        await #expect(processExitsWith: .failure) {
            let outer = Mutex(0, rank: MutexRank("test.outer", order: 1))
            let inner = Mutex(0, rank: MutexRank("test.inner", order: 2))
            _ = inner.withLockIfAvailable { _ in outer.withLock { $0 += 1 } }
        }
    }
    #endif
}
