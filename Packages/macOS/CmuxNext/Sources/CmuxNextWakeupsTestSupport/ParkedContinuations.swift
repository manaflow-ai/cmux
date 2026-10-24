/// Tasks parked on a continuation until their owner lets them go, each with a tag: a sleeper's
/// deadline on a ``ManualClock``, nothing for a caller that waits for an arrival.
///
/// It is the one park and cancel path of this target: the clock's sleepers, the clock's
/// ``ManualClock/waitForSleeper()`` callers and the executor's ``ManualSerialExecutor/waitForJob()``
/// callers all use it. It lives inside its owner's mutex, so the owner's check ("has it arrived?",
/// "is the deadline reached?") and the parking are one critical section: nothing that happens
/// between the two can be missed, and nothing polls. The owner resumes the continuations it takes
/// outside the lock.
///
/// A waiter's id is taken (``newID()``) before it parks, so its cancel handler can name it even
/// when the cancel comes first. An id is forgotten once it is parked and taken, failed as it
/// parks, or cancelled, so a long test does not grow the bookkeeping.
struct ParkedContinuations<Tag> {
    typealias Continuation = CheckedContinuation<Void, any Error>

    /// One parked task: its id, its tag and its continuation.
    private struct Parked {
        let id: Int
        let tag: Tag
        let continuation: Continuation
    }

    private var parked: [Parked] = []
    /// Ids handed out by ``newID()`` that have not parked or been cancelled yet.
    private var issued: Set<Int> = []
    /// Issued ids whose cancel handler ran before they parked.
    private var cancelledBeforeParking: Set<Int> = []
    private var lastID = 0

    /// Whether no task is parked.
    var isEmpty: Bool {
        parked.isEmpty
    }

    /// A new id for a task about to park.
    mutating func newID() -> Int {
        lastID += 1
        issued.insert(lastID)
        return lastID
    }

    /// Parks `continuation` under `id` with `tag`, unless it may go on at once.
    ///
    /// - Parameters:
    ///   - id: The task's id from ``newID()``.
    ///   - tag: What the owner later selects on in ``take(where:)``.
    ///   - continuation: The task's continuation.
    ///   - arrived: Whether what the task waits for is here already.
    /// - Returns: The outcome to resume `continuation` with at once, outside the lock:
    ///   `CancellationError` when the task was cancelled before it parked, success when `arrived`.
    ///   Nil when it parked.
    mutating func park(_ id: Int, tag: Tag, _ continuation: Continuation, arrived: Bool) -> Result<Void, any Error>? {
        issued.remove(id)
        if cancelledBeforeParking.remove(id) != nil { return .failure(CancellationError()) }
        if arrived { return .success(()) }
        parked.append(Parked(id: id, tag: tag, continuation: continuation))
        return nil
    }

    /// Removes the task `id` because it was cancelled.
    ///
    /// - Returns: Its continuation when it is parked, to resume with `CancellationError` outside the
    ///   lock. Nil when it has not parked yet (``park(_:tag:_:arrived:)`` then fails it) or when it
    ///   was already let go.
    mutating func cancel(_ id: Int) -> Continuation? {
        if let index = parked.firstIndex(where: { $0.id == id }) {
            return parked.remove(at: index).continuation
        }
        if issued.remove(id) != nil { cancelledBeforeParking.insert(id) }
        return nil
    }

    /// Removes every parked task whose tag `isDue` selects.
    ///
    /// - Parameter isDue: Whether the task with this tag goes on now.
    /// - Returns: Their continuations, in parking order, to resume outside the lock.
    mutating func take(where isDue: (Tag) -> Bool) -> [Continuation] {
        var taken: [Continuation] = []
        parked.removeAll { entry in
            guard isDue(entry.tag) else { return false }
            taken.append(entry.continuation)
            return true
        }
        return taken
    }

    /// Removes every parked task: an arrival lets them all go.
    ///
    /// - Returns: Their continuations, to resume outside the lock.
    mutating func takeAll() -> [Continuation] {
        take { _ in true }
    }
}

extension ParkedContinuations where Tag == Void {
    /// Parks a task that waits for an arrival and carries no tag.
    mutating func park(_ id: Int, _ continuation: Continuation, arrived: Bool) -> Result<Void, any Error>? {
        park(id, tag: (), continuation, arrived: arrived)
    }
}

/// What parking decided, computed inside the owner's lock and acted on outside it.
struct ParkDecision {
    /// The outcome to resume the parking task with at once; nil when it parked.
    var resumeNow: Result<Void, any Error>?
    /// Other parked tasks the parking lets go (a sleeper's arrival wakes its waiters).
    var wake: [CheckedContinuation<Void, any Error>] = []
}

/// Parks the calling task until its owner takes it, and ends it with `CancellationError` when the
/// task is cancelled, also when the cancel comes before it parks.
///
/// - Parameters:
///   - park: Runs once with the task's continuation; it takes the owner's lock, parks the
///     continuation in a ``ParkedContinuations`` (or decides it may go on) and returns the
///     decision. The continuations it returns are resumed after the lock is released.
///   - cancel: Runs from the cancel handler; it takes the owner's lock and returns
///     ``ParkedContinuations/cancel(_:)``'s result.
/// - Throws: `CancellationError` when the task is cancelled, or the error `park` decided.
func parkUntilTaken(
    _ park: (CheckedContinuation<Void, any Error>) -> ParkDecision,
    cancel: @Sendable () -> CheckedContinuation<Void, any Error>?
) async throws {
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let decision = park(continuation)
            if let outcome = decision.resumeNow { continuation.resume(with: outcome) }
            for other in decision.wake { other.resume() }
        }
    } onCancel: {
        cancel()?.resume(throwing: CancellationError())
    }
}
