internal import Foundation
internal import os

/// The result of one ``ControlBoundedHop`` run.
public enum ControlBoundedHopOutcome<Value: Sendable>: Sendable {
    /// The body ran to completion before the deadline.
    case completed(Value)
    /// The deadline elapsed while the body was still queued behind the
    /// target executor. The body was withdrawn and will never run, so the
    /// client can safely retry the command.
    case abandoned
    /// The deadline elapsed after the body had started. Its side effects may
    /// have been applied; the caller stopped waiting for the result.
    case timedOutWhileRunning
    /// The calling task was cancelled before the body produced a value. A
    /// queued body is withdrawn; a running body finishes into the void.
    case cancelled
}

/// A deadline-bounded hop of one socket connection task onto another
/// executor: the main actor for command bodies, or the blocking legacy lane.
///
/// A control command must never park a connection job forever behind a
/// stalled executor (a nested modal run loop on the main thread, for
/// example): that is how the connection pool saturated and every new client
/// saw `EPIPE` in <https://github.com/manaflow-ai/cmux/issues/13369>. The hop
/// schedules `body` through `schedule`, then waits for the first of three
/// events: the body completing, the deadline elapsing on ``clock``, or the
/// caller's cancellation.
///
/// A phase gate decides exactly once between "the body ran" and "the deadline
/// (or cancellation) withdrew it while still queued". A withdrawn body is a
/// no-op when the executor finally reaches it, so a command that timed out
/// never runs late with stale side effects after the client was told it did
/// not run. The outcome distinguishes ``ControlBoundedHopOutcome/abandoned``
/// (safe to retry) from ``ControlBoundedHopOutcome/timedOutWhileRunning``.
///
/// ```swift
/// let hop = ControlBoundedHop(deadlineMilliseconds: 10_000)
/// let outcome = await hop.run(
///     schedule: { job in Task { @MainActor in job() } },
///     body: { MainActor.assumeIsolated { coordinator.handle(request) } }
/// )
/// ```
public struct ControlBoundedHop: Sendable {
    /// The deadline, measured on ``clock`` from the moment `body` is scheduled.
    public let deadlineMilliseconds: Int
    /// The deadline clock; tests inject a virtual clock.
    public let clock: any SocketRecoveryClock

    private enum Phase: Sendable {
        case queued
        case running
        case withdrawn
    }

    /// Creates a bounded hop.
    ///
    /// - Parameters:
    ///   - deadlineMilliseconds: The deadline for the whole hop (queue wait
    ///     plus body).
    ///   - clock: The deadline clock; defaults to the continuous clock.
    public init(
        deadlineMilliseconds: Int,
        clock: any SocketRecoveryClock = SystemSocketRecoveryClock()
    ) {
        self.deadlineMilliseconds = max(0, deadlineMilliseconds)
        self.clock = clock
    }

    /// Schedules `body` through `schedule` and waits for it, the deadline, or
    /// cancellation, whichever comes first.
    ///
    /// - Parameters:
    ///   - schedule: Enqueues one job on the target executor. The job runs
    ///     the phase check and, when admitted, `body`; it must be invoked at
    ///     most once.
    ///   - body: The work to run on the target executor.
    /// - Returns: The hop outcome.
    public func run<Value: Sendable>(
        schedule: @escaping @Sendable (_ job: @escaping @Sendable () -> Void) -> Void,
        body: @escaping @Sendable () -> Value
    ) async -> ControlBoundedHopOutcome<Value> {
        // Lock carve-out: a synchronous compare-and-set shared by the target
        // executor's job, the deadline task, and the cancellation handler,
        // none of which can await. The lock never spans the body.
        let phase = OSAllocatedUnfairLock(initialState: Phase.queued)
        let (outcomes, continuation) = AsyncStream<ControlBoundedHopOutcome<Value>>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )

        schedule {
            let admitted = phase.withLock { state -> Bool in
                guard state == .queued else { return false }
                state = .running
                return true
            }
            guard admitted else { return }
            continuation.yield(.completed(body()))
            continuation.finish()
        }

        // Genuine request deadline on the injected clock; cancelled as soon
        // as the body or the caller settles the outcome.
        let deadline = Task {
            do {
                try await clock.sleep(forMilliseconds: deadlineMilliseconds)
            } catch {
                return
            }
            let withdrew = phase.withLock { state -> Bool in
                guard state == .queued else { return false }
                state = .withdrawn
                return true
            }
            continuation.yield(withdrew ? .abandoned : .timedOutWhileRunning)
            continuation.finish()
        }

        let outcome = await withTaskCancellationHandler {
            var iterator = outcomes.makeAsyncIterator()
            return await iterator.next()
        } onCancel: {
            phase.withLock { state in
                if state == .queued { state = .withdrawn }
            }
            deadline.cancel()
            continuation.finish()
        }
        deadline.cancel()
        return outcome ?? .cancelled
    }
}
