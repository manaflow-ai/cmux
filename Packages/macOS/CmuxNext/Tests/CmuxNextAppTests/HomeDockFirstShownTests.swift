import CmuxNextCompat
@testable import CmuxNextHomeEngine
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import struct CmuxSafeConcurrency.OnceContinuationFault
import struct CmuxSafeConcurrency.OnceContinuationFaultReporter
import func CmuxSafeConcurrency.withOnceContinuation
import Foundation
import Observation
import Testing

/// p06 sweep (group 333): HomeDock's tree waits answer once. The first non-nil value resumes the wait and
/// stops the observation at once, so later tree changes before the waiting task stops it apply nothing: no
/// second resume of the one continuation (a `resumedTwice` fault) and no further read.
@MainActor @Suite(.timeLimit(.minutes(1))) struct HomeDockFirstShownTests {
    @Test func theFirstValueAnswersOnceAndStopsTheObservation() async {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        let tree = Tree()
        let faults = FaultLog()
        let first = HomeDockFirstShown<Int>()
        let reads = Reads()
        let wait = Task { @MainActor in
            try? await withOnceContinuation(cancellation: .cancellable, failingWith: { $0 }, faults: faults.reporter) {
                (answer: OnceContinuation<Int, OnceContinuationError>) in
                first.start(answer, on: work) {
                    reads.count += 1
                    return tree.value
                }
            }
        }
        // Main-actor tasks run in the order they were made: the wait observes before the change.
        let filed = Task { @MainActor in reads.count }
        #expect(await filed.value == 1, "the start reads once")
        tree.value = 1
        #expect(await wait.value == 1)
        let readsAtAnswer = reads.count

        // The waiting task has not stopped `first` (as HomeDock.shown does after its resume): changes now
        // must still apply nothing. A witness on the same tree lets every flush they posted run.
        let witness = Witness()
        let watch = ServiceObservation(.visible, owner: "HomeDockFirstShownTests.witness", on: work, read: { tree.value }) {
            witness.received($0)
        }
        for next in [2, 3] {
            tree.value = next
            await witness.next()
        }
        watch.cancel()
        #expect(witness.all == [1, 2, 3])
        #expect(reads.count == readsAtAnswer, "an answered wait reads nothing more")
        #expect(faults.recorded.isEmpty, "the continuation is resumed once")
        first.stop()
    }

    @Test func aCancelledWaitEndsWithNilAndStopsOnStop() async {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        let tree = Tree()
        let faults = FaultLog()
        let first = HomeDockFirstShown<Int>()
        let reads = Reads()
        let wait = Task { @MainActor in
            let value = try? await withOnceContinuation(cancellation: .cancellable, failingWith: { $0 }, faults: faults.reporter) {
                (answer: OnceContinuation<Int, OnceContinuationError>) in
                first.start(answer, on: work) {
                    reads.count += 1
                    return tree.value
                }
            }
            first.stop()
            return value
        }
        let filed = Task { @MainActor in reads.count }
        #expect(await filed.value == 1)
        wait.cancel()
        #expect(await wait.value == nil)
        let witness = Witness()
        let watch = ServiceObservation(.visible, owner: "HomeDockFirstShownTests.witness", on: work, read: { tree.value }) {
            witness.received($0)
        }
        tree.value = 1
        await witness.next()
        watch.cancel()
        #expect(reads.count == 1, "a stopped wait reads nothing more")
        #expect(faults.recorded.isEmpty)
    }

    @MainActor @Observable final class Tree {
        var value: Int?
    }

    @MainActor final class Reads {
        var count = 0
    }

    /// The values a witness observation applied, with one wait for the next.
    @MainActor final class Witness {
        private(set) var all: [Int?] = []
        private var waiter: CheckedContinuation<Void, Never>?

        func received(_ value: Int?) {
            all.append(value)
            waiter?.resume()
            waiter = nil
        }

        func next() async {
            await withCheckedContinuation { waiter = $0 }
        }
    }
}

private nonisolated final class FaultLog: Sendable {
    private let faults = Mutex<[OnceContinuationFault]>([])

    var reporter: OnceContinuationFaultReporter {
        OnceContinuationFaultReporter { fault in self.record(fault) }
    }

    func record(_ fault: OnceContinuationFault) {
        faults.withLock { $0.append(fault) }
    }

    var recorded: [OnceContinuationFault] {
        faults.withLock { $0 }
    }
}
