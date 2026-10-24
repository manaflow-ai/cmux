/// The test callers parked until something arrives: a timer asleep on a ``ManualClock``, a job on a
/// ``ManualSerialExecutor``.
///
/// It lives inside its owner's mutex, so the check "has it arrived?" and the parking are one critical
/// section: an arrival between the two cannot be missed, and nothing polls. The arrival itself takes
/// every parked waiter (``takeAll()``) and resumes them outside the lock.
struct ArrivalWaiters {
    /// One parked waiter: its id (to find it again when its task is cancelled) and its continuation.
    private struct Parked {
        let id: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var parked: [Parked] = []
    /// Waiters whose task was cancelled before they parked: the cancel handler ran first.
    private var cancelledBeforeParking: Set<Int> = []
    private var lastID = 0

    /// A new waiter id, taken before the waiter parks so that its cancel handler can name it.
    mutating func newID() -> Int {
        lastID += 1
        return lastID
    }

    /// Parks `continuation` unless the arrival is here already or the waiter was cancelled first.
    ///
    /// - Parameters:
    ///   - id: The waiter's id from ``newID()``.
    ///   - continuation: The waiter's continuation; it stays parked until ``takeAll()`` or ``cancel(_:)``.
    ///   - arrived: Whether the owner already holds what the waiter waits for.
    /// - Returns: The outcome to resume `continuation` with at once (outside the lock), or nil when it parked.
    mutating func park(
        _ id: Int,
        _ continuation: CheckedContinuation<Void, any Error>,
        arrived: Bool
    ) -> Result<Void, any Error>? {
        if cancelledBeforeParking.remove(id) != nil { return .failure(CancellationError()) }
        if arrived { return .success(()) }
        parked.append(Parked(id: id, continuation: continuation))
        return nil
    }

    /// Removes the parked waiter `id` because its task was cancelled.
    ///
    /// - Returns: Its continuation, to resume with `CancellationError` outside the lock; nil when it has
    ///   not parked yet, in which case ``park(_:_:arrived:)`` fails it as it parks.
    mutating func cancel(_ id: Int) -> CheckedContinuation<Void, any Error>? {
        guard let index = parked.firstIndex(where: { $0.id == id }) else {
            cancelledBeforeParking.insert(id)
            return nil
        }
        return parked.remove(at: index).continuation
    }

    /// Removes every parked waiter: an arrival wakes them all.
    ///
    /// - Returns: Their continuations, to resume outside the lock.
    mutating func takeAll() -> [CheckedContinuation<Void, any Error>] {
        let continuations = parked.map { $0.continuation }
        parked.removeAll()
        return continuations
    }
}
