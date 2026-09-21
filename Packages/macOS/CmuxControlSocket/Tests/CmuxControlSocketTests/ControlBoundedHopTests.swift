import CmuxControlSocket
import Dispatch
import Foundation
import os
import Testing

/// A target executor the test drives by hand: jobs are parked until the test
/// runs them, standing in for a main actor that is stalled behind a nested
/// modal run loop.
private final class ManualExecutor: Sendable {
    private let jobs = OSAllocatedUnfairLock(initialState: [@Sendable () -> Void]())

    func schedule(_ job: @escaping @Sendable () -> Void) {
        jobs.withLock { $0.append(job) }
    }

    var queuedJobCount: Int {
        jobs.withLock { $0.count }
    }

    /// Runs every parked job, as a stall ending would.
    func drain() {
        let parked = jobs.withLock { jobs -> [@Sendable () -> Void] in
            let parked = jobs
            jobs.removeAll()
            return parked
        }
        for job in parked {
            job()
        }
    }
}

private final class BodyProbe: Sendable {
    private let runs = OSAllocatedUnfairLock(initialState: 0)

    func record() {
        runs.withLock { $0 += 1 }
    }

    var runCount: Int {
        runs.withLock { $0 }
    }
}

@Suite("ControlBoundedHop")
struct ControlBoundedHopTests {
    @Test func completesWhenTheExecutorRunsTheBodyBeforeTheDeadline() async {
        let clock = TestSocketRecoveryClock()
        let executor = ManualExecutor()
        let probe = BodyProbe()
        let hop = ControlBoundedHop(deadlineMilliseconds: 10_000, clock: clock)

        let outcome = await hop.run(
            schedule: { job in
                executor.schedule(job)
                executor.drain()
            },
            body: {
                probe.record()
                return "done"
            }
        )

        guard case .completed(let value) = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        #expect(value == "done")
        #expect(probe.runCount == 1)
        #expect(clock.pendingSleepCount == 0)
    }

    @Test func abandonsAQueuedBodyWhenTheDeadlineElapsesAndNeverRunsItLate() async {
        let clock = TestSocketRecoveryClock()
        let executor = ManualExecutor()
        let probe = BodyProbe()
        let hop = ControlBoundedHop(deadlineMilliseconds: 10_000, clock: clock)

        // The executor is stalled: the job is parked and the deadline fires.
        clock.advance()
        let outcome = await hop.run(
            schedule: { job in executor.schedule(job) },
            body: { () -> Int in
                probe.record()
                return 1
            }
        )

        guard case .abandoned = outcome else {
            Issue.record("expected the queued body to be abandoned, got \(outcome)")
            return
        }
        #expect(executor.queuedJobCount == 1)

        // The stall ends and the executor reaches the withdrawn job: the
        // command must not run late against a client that was told it did
        // not run.
        executor.drain()
        #expect(probe.runCount == 0)
    }

    @Test func reportsATimeoutWhileRunningWhenTheBodyAlreadyStarted() async {
        let clock = TestSocketRecoveryClock()
        let probe = BodyProbe()
        let hop = ControlBoundedHop(deadlineMilliseconds: 10_000, clock: clock)
        // The body signals its start through an async stream the test awaits,
        // and is held inside `running` by a semaphore it waits on from its own
        // GCD thread (never from an async context).
        let (bodyStarted, bodyStartedContinuation) = AsyncStream<Void>.makeStream()
        let bodyMayFinish = DispatchSemaphore(value: 0)

        async let outcome = hop.run(
            schedule: { job in
                DispatchQueue.global(qos: .utility).async(execute: job)
            },
            body: { () -> Int in
                bodyStartedContinuation.yield(())
                bodyStartedContinuation.finish()
                bodyMayFinish.wait()
                probe.record()
                return 2
            }
        )
        var startedIterator = bodyStarted.makeAsyncIterator()
        _ = await startedIterator.next()
        // Fire the deadline only once the body is provably running.
        clock.advance()
        let result = await outcome

        guard case .timedOutWhileRunning = result else {
            Issue.record("expected a running-body timeout, got \(result)")
            bodyMayFinish.signal()
            return
        }
        bodyMayFinish.signal()
        for _ in 0..<10_000 where probe.runCount == 0 {
            await Task.yield()
        }
        #expect(probe.runCount == 1)
    }

    @Test func withdrawsAQueuedBodyWhenTheCallerIsCancelled() async {
        let clock = TestSocketRecoveryClock()
        let executor = ManualExecutor()
        let probe = BodyProbe()
        let hop = ControlBoundedHop(deadlineMilliseconds: 10_000, clock: clock)

        let caller = Task {
            await hop.run(
                schedule: { job in executor.schedule(job) },
                body: { () -> Int in
                    probe.record()
                    return 3
                }
            )
        }
        for _ in 0..<10_000 where executor.queuedJobCount == 0 {
            await Task.yield()
        }
        caller.cancel()

        guard case .cancelled = await caller.value else {
            Issue.record("expected cancellation to settle the hop")
            return
        }
        executor.drain()
        #expect(probe.runCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }
}
