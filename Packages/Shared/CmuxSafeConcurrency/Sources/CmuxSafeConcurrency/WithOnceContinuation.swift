/// Suspends the current task, calls `body` with a ``OnceContinuation`` for it, and returns the value the
/// continuation resumes with. The replacement for `withCheckedContinuation`: a dropped continuation throws
/// ``OnceContinuationError/abandoned`` instead of hanging, and a second resume is a no-op instead of a crash.
/// Cancellation does not end the wait, as with the raw one. A cancellable wait throws `CancellationError`
/// from ``withOnceThrowingContinuation(isolation:cancellation:faults:function:fileID:line:_:)``, or the
/// caller's own mapping of ``OnceContinuationError/cancelled`` from
/// ``withOnceContinuation(isolation:cancellation:failingWith:faults:function:fileID:line:_:)``.
public func withOnceContinuation<Success: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    faults: OnceContinuationFaultReporter = .systemLog,
    function: String = #function,
    fileID: String = #fileID,
    line: Int = #line,
    _ body: (OnceContinuation<Success, OnceContinuationError>) -> Void
) async throws(OnceContinuationError) -> Success {
    try await withOnceContinuation(
        isolation: isolation,
        cancellation: .notCancellable,
        failingWith: { $0 },
        faults: faults,
        function: function,
        fileID: fileID,
        line: line,
        body
    )
}

/// ``withOnceContinuation(isolation:faults:function:fileID:line:_:)`` for a producer that can
/// fail with any error. The replacement for `withCheckedThrowingContinuation`: a dropped continuation throws
/// ``OnceContinuationError/abandoned``; a cancelled `.cancellable` wait throws `CancellationError`.
public func withOnceThrowingContinuation<Success: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    cancellation: OnceContinuationCancellation = .notCancellable,
    faults: OnceContinuationFaultReporter = .systemLog,
    function: String = #function,
    fileID: String = #fileID,
    line: Int = #line,
    _ body: (OnceContinuation<Success, any Error>) -> Void
) async throws -> Success {
    try await withOnceContinuation(
        isolation: isolation,
        cancellation: cancellation,
        failingWith: { $0.thrown },
        faults: faults,
        function: function,
        fileID: fileID,
        line: line,
        body
    )
}

/// ``withOnceContinuation(isolation:faults:function:fileID:line:_:)`` for a producer with a typed
/// error: `ending` turns an abandoned or cancelled wait into a `Failure`, which the call throws. A
/// `.cancellable` wait that should end as `CancellationError` maps through ``OnceContinuationError/thrown``
/// or uses ``withOnceThrowingContinuation(isolation:cancellation:faults:function:fileID:line:_:)``.
public func withOnceContinuation<Success: Sendable, Failure: Error>(
    isolation: isolated (any Actor)? = #isolation,
    cancellation: OnceContinuationCancellation = .notCancellable,
    failingWith ending: @escaping @Sendable (OnceContinuationError) -> Failure,
    faults: OnceContinuationFaultReporter = .systemLog,
    function: String = #function,
    fileID: String = #fileID,
    line: Int = #line,
    _ body: (OnceContinuation<Success, Failure>) -> Void
) async throws(Failure) -> Success {
    let site = OnceContinuationFault.Site(function: function, fileID: fileID, line: line)
    let result: Result<Success, Failure>
    switch cancellation {
    case .notCancellable:
        // The function holds no reference to the continuation while it waits: only the producer does, so
        // dropping it ends the wait (OnceContinuation's deinit).
        result = await withCheckedContinuation(isolation: isolation, function: function) { raw in
            body(OnceContinuation(raw, ending: ending, faults: faults, site: site))
        }
    case .cancellable:
        let target = OnceContinuationCancelTarget<Success, Failure>()
        result = await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation(isolation: isolation, function: function) { raw in
                    let once = OnceContinuation(raw, ending: ending, faults: faults, site: site)
                    target.attach(once)
                    body(once)
                }
            },
            onCancel: { target.cancel() },
            isolation: isolation
        )
    }
    return try result.get()
}

/// The continuation a cancellable wait's cancellation handler ends. The handler can run before the
/// continuation exists (a task cancelled before the wait) or on another thread while it is made, so the
/// target remembers a cancellation that came first. It holds the continuation weakly: the producer alone
/// keeps it alive, and dropping it still ends the wait.
final class OnceContinuationCancelTarget<Success: Sendable, Failure: Error>: Sendable {
    private struct Slot {
        weak var once: OnceContinuation<Success, Failure>?
        var cancelled = false
    }

    private let slot = Mutex(Slot())

    /// Makes `once` the continuation to cancel; cancels it now when the task was cancelled first.
    func attach(_ once: OnceContinuation<Success, Failure>) {
        let cancelledFirst: Bool = slot.withLock { current in
            current.once = once
            return current.cancelled
        }
        if cancelledFirst {
            once.cancel()
        }
    }

    /// The task was cancelled: ends the attached continuation's wait, or the one attached later.
    func cancel() {
        let attached: OnceContinuation<Success, Failure>? = slot.withLock { current in
            current.cancelled = true
            return current.once
        }
        attached?.cancel()
    }
}
