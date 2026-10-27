import CmuxSafeConcurrency
import Dispatch
import Testing

/// The faults the continuations under test report, in order.
private final class FaultLog: Sendable {
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

    var kinds: [OnceContinuationFault.Kind] {
        recorded.map(\.kind)
    }
}

/// What each resume call returned, from any thread.
private final class Outcomes: Sendable {
    private let values = Mutex<[Bool]>([])

    func record(_ value: Bool) {
        values.withLock { $0.append(value) }
    }

    var recorded: [Bool] {
        values.withLock { $0 }
    }
}

/// Holds a producer's continuation, as a callback-based API would, so the test can resume or drop it later.
private final class Parked<Success: Sendable, Failure: Error>: Sendable {
    private let slot = Mutex<OnceContinuation<Success, Failure>?>(nil)

    func park(_ once: OnceContinuation<Success, Failure>) {
        slot.withLock { $0 = once }
    }

    /// The parked continuation; it stays parked.
    var continuation: OnceContinuation<Success, Failure>? {
        slot.withLock { $0 }
    }

    /// Lets go of the parked continuation (its last reference when the caller holds none).
    func drop() {
        let taken: OnceContinuation<Success, Failure>? = slot.withLock { current in
            let previous = current
            current = nil
            return previous
        }
        _ = consume taken
    }
}

private typealias IntOnce = OnceContinuation<Int, OnceContinuationError>
private typealias ThrowingOnce = OnceContinuation<Int, any Error>

private struct Boom: Error, Equatable {}

private enum FetchError: Error, Equatable {
    case failed(Int)
    case ended(OnceContinuationError)
}

private let thisFile = "CmuxSafeConcurrencyTests/OnceContinuationTests.swift"

@Suite struct OnceContinuationTests {
    @Test func aResumeDeliversItsValue() async throws {
        let log = FaultLog()
        let value: Int = try await withOnceContinuation(faults: log.reporter) { once in
            once.resume(returning: 42)
        }
        #expect(value == 42)
        #expect(log.recorded.isEmpty)
    }

    @Test func aSecondResumeIsANoOpThatReportsAFault() async throws {
        let log = FaultLog()
        var outcomes: [Bool] = []
        let value: Int = try await withOnceContinuation(faults: log.reporter) { once in
            outcomes.append(once.resume(returning: 1))
            outcomes.append(once.resume(returning: 2))
            outcomes.append(once.resume(throwing: .abandoned))
        }
        #expect(value == 1)
        #expect(outcomes == [true, false, false])
        #expect(log.kinds == [.resumedTwice, .resumedTwice])
        #expect(log.recorded.first?.site.fileID == thisFile)
        #expect(log.recorded.first?.message.hasPrefix("OnceContinuation made in") == true)
    }

    @Test func racingResumesResumeTheTaskOnce() async throws {
        let log = FaultLog()
        let outcomes = Outcomes()
        let racers = 64
        let value: Int = try await withOnceContinuation(faults: log.reporter) { once in
            DispatchQueue.concurrentPerform(iterations: racers) { index in
                outcomes.record(once.resume(returning: index))
            }
        }
        #expect((0..<racers).contains(value))
        #expect(outcomes.recorded.filter { $0 }.count == 1)
        #expect(outcomes.recorded.count == racers)
        #expect(log.kinds == Array(repeating: .resumedTwice, count: racers - 1))
    }

    @Test func aContinuationDroppedInTheBodyThrowsAbandoned() async {
        let log = FaultLog()
        await #expect(throws: OnceContinuationError.abandoned) {
            let _: Int = try await withOnceContinuation(faults: log.reporter) { _ in }
        }
        #expect(log.kinds == [.abandoned])
        #expect(log.recorded.first?.site.fileID == thisFile)
    }

    @Test func aContinuationDroppedLaterByItsProducerThrowsAbandoned() async {
        let log = FaultLog()
        let parked = Parked<Int, OnceContinuationError>()
        let (ready, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await withOnceContinuation(faults: log.reporter) { (once: IntOnce) in
                parked.park(once)
                signal.yield()
            }
        }
        for await _ in ready { break }
        #expect(log.recorded.isEmpty)
        parked.drop()
        await #expect(throws: OnceContinuationError.abandoned) { try await task.value }
        #expect(log.kinds == [.abandoned])
    }

    @Test func theThrowingVariantDeliversTheProducersError() async {
        let log = FaultLog()
        await #expect(throws: Boom()) {
            let _: Int = try await withOnceThrowingContinuation(faults: log.reporter) { once in
                once.resume(throwing: Boom())
            }
        }
        #expect(log.recorded.isEmpty)
    }

    @Test func theThrowingVariantThrowsAbandonedForADroppedContinuation() async {
        let log = FaultLog()
        await #expect(throws: OnceContinuationError.abandoned) {
            let _: Int = try await withOnceThrowingContinuation(faults: log.reporter) { _ in }
        }
        #expect(log.kinds == [.abandoned])
    }

    @Test func aTypedFailureCarriesTheProducersErrorAndTheEnding() async {
        let log = FaultLog()
        await #expect(throws: FetchError.failed(3)) {
            let _: Int = try await withOnceContinuation(
                failingWith: { FetchError.ended($0) },
                faults: log.reporter
            ) { once in
                once.resume(throwing: .failed(3))
            }
        }
        await #expect(throws: FetchError.ended(.abandoned)) {
            let _: Int = try await withOnceContinuation(
                failingWith: { FetchError.ended($0) },
                faults: log.reporter
            ) { _ in }
        }
        #expect(log.kinds == [.abandoned])
    }

    @Test func cancellationDoesNotEndANonCancellableWait() async throws {
        let log = FaultLog()
        let parked = Parked<Int, OnceContinuationError>()
        let (ready, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await withOnceContinuation(faults: log.reporter) { (once: IntOnce) in
                parked.park(once)
                signal.yield()
            }
        }
        for await _ in ready { break }
        task.cancel()
        let once = try #require(parked.continuation)
        #expect(once.resume(returning: 7))
        #expect(try await task.value == 7)
        #expect(log.recorded.isEmpty)
    }

    @Test func cancellationEndsACancellableWaitAndTheLateResumeIsNoFault() async throws {
        let log = FaultLog()
        let parked = Parked<Int, OnceContinuationError>()
        let (ready, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await withOnceContinuation(
                cancellation: .cancellable,
                failingWith: { $0 },
                faults: log.reporter
            ) { (once: IntOnce) in
                parked.park(once)
                signal.yield()
            }
        }
        for await _ in ready { break }
        task.cancel()
        await #expect(throws: OnceContinuationError.cancelled) { try await task.value }
        let once = try #require(parked.continuation)
        #expect(!once.resume(returning: 7))
        parked.drop()
        #expect(log.recorded.isEmpty)
    }

    @Test func aSecondResumeAfterACancelIsADoubleResumeFault() async throws {
        let log = FaultLog()
        let parked = Parked<Int, OnceContinuationError>()
        let (ready, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await withOnceContinuation(
                cancellation: .cancellable,
                failingWith: { $0 },
                faults: log.reporter
            ) { (once: IntOnce) in
                parked.park(once)
                signal.yield()
            }
        }
        for await _ in ready { break }
        task.cancel()
        await #expect(throws: OnceContinuationError.cancelled) { try await task.value }
        let once = try #require(parked.continuation)
        let outcomes = [once.resume(returning: 1), once.resume(returning: 2)]
        #expect(outcomes == [false, false])
        #expect(log.kinds == [.resumedTwice])
        parked.drop()
        #expect(log.kinds == [.resumedTwice])
    }

    @Test(arguments: [OnceContinuationCancellation.notCancellable, .cancellable])
    func aTaskCancelledBeforeTheWait(cancellation: OnceContinuationCancellation) async {
        let log = FaultLog()
        let outcomes = Outcomes()
        // The gate's stream stays open until the end, so only the cancellation lets the task through it: the
        // task is cancelled before it starts to wait.
        let (gate, opener) = AsyncStream<Void>.makeStream()
        let task = Task { () async -> Result<Int, OnceContinuationError> in
            for await _ in gate { break }
            do throws(OnceContinuationError) {
                let value: Int = try await withOnceContinuation(
                    cancellation: cancellation,
                    failingWith: { $0 },
                    faults: log.reporter
                ) { once in
                    outcomes.record(once.resume(returning: 1))
                }
                return .success(value)
            } catch {
                return .failure(error)
            }
        }
        task.cancel()
        let result = await task.value
        opener.finish()
        switch cancellation {
        case .notCancellable:
            #expect(result == .success(1))
            #expect(outcomes.recorded == [true])
        case .cancellable:
            #expect(result == .failure(.cancelled))
            #expect(outcomes.recorded == [false])
        }
        #expect(log.recorded.isEmpty)
    }

    @Test func theThrowingVariantThrowsCancellationErrorForACancelledWait() async {
        let log = FaultLog()
        let (ready, signal) = AsyncStream<Void>.makeStream()
        let parked = Parked<Int, any Error>()
        let task = Task {
            try await withOnceThrowingContinuation(
                cancellation: .cancellable,
                faults: log.reporter
            ) { (once: ThrowingOnce) in
                parked.park(once)
                signal.yield()
            }
        }
        for await _ in ready { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        parked.drop()
        #expect(log.recorded.isEmpty)
    }

    /// Cancellation and a resume race from two threads: the task ends exactly once, with one of the two, and
    /// neither side reports a fault (TSan watches the handoff).
    @Test func cancellationRacingAResumeEndsTheWaitOnce() async throws {
        let log = FaultLog()
        for round in 0..<200 {
            let parked = Parked<Int, OnceContinuationError>()
            let (ready, signal) = AsyncStream<Void>.makeStream()
            let task = Task {
                try await withOnceContinuation(
                    cancellation: .cancellable,
                    failingWith: { $0 },
                    faults: log.reporter
                ) { (once: IntOnce) in
                    parked.park(once)
                    signal.yield()
                }
            }
            for await _ in ready { break }
            let once = try #require(parked.continuation)
            let outcomes = Outcomes()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    task.cancel()
                } else {
                    outcomes.record(once.resume(returning: round))
                }
            }
            let result = await task.result
            switch result {
            case .success(let value):
                #expect(value == round)
                #expect(outcomes.recorded == [true])
            case .failure(let error):
                #expect(error as? OnceContinuationError == .cancelled)
                #expect(outcomes.recorded == [false])
            }
            parked.drop()
        }
        #expect(log.recorded.isEmpty)
    }
}
