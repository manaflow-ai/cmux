/// A byte bound with backpressure between one producer and one consumer of a buffer (an
/// `AsyncStream` of chunks): the producer counts each chunk it hands over and pauses its source (it
/// stops reading the descriptor or socket, or stops sending) once the consumer has `limit` bytes it
/// has not taken; the consumer counts each chunk it took, and the producer resumes once at most
/// half the limit is left. The buffer then holds at most `limit` plus the one chunk that filled it.
///
/// Chrome's Mojo data pipe works the same way (mojo/core/data_pipe_producer_dispatcher.cc): a write
/// past the pipe's capacity returns `MOJO_RESULT_SHOULD_WAIT`, and the consumer's reads give the
/// producer `MOJO_HANDLE_SIGNAL_WRITABLE` back. cmux-tui's outbound queues bound their bytes the same
/// way (cmux-tui-core server/bounded_outbound.rs).
///
/// Lock-free. One producer calls ``produced(_:)`` and pauses its source when it returns true; the
/// consumer calls ``consumed(_:)`` and, when that returns true, has the producer's context call
/// ``resumeIfDrained()``, which says whether to resume the source. A producer whose pause and resume
/// must pair (a `DispatchSource`'s suspend and resume) runs both on its own serial queue.
public nonisolated final class ByteCreditWindow: Sendable {
    /// The bytes the consumer may hold before the producer pauses.
    public let limit: Int
    /// The producer resumes once the consumer holds at most this many bytes.
    public var resumeAt: Int { limit / 2 }

    private let outstanding = Atomic<Int>(0)
    private let paused = Atomic<Bool>(false)

    /// - Parameter limit: The bytes the consumer may hold before the producer pauses (at least 1).
    public init(limit: Int) {
        self.limit = max(limit, 1)
    }

    /// Bytes handed over and not taken yet.
    public var bufferedBytes: Int { outstanding.load(ordering: .sequentiallyConsistent) }

    /// True while the producer is paused for the consumer.
    public var isPaused: Bool { paused.load(ordering: .sequentiallyConsistent) }

    /// Counts `count` bytes handed to the consumer. True when the window is now full: the producer
    /// pauses its source. A consumer that drained the window before the pause took hold undoes it
    /// here (its ``consumed(_:)`` found nothing paused), so the producer never waits for a consumer
    /// that has nothing left.
    public func produced(_ count: Int) -> Bool {
        let now = outstanding.add(count, ordering: .sequentiallyConsistent).newValue
        guard now >= limit, paused.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged
        else { return false }
        guard outstanding.load(ordering: .sequentiallyConsistent) <= resumeAt else { return true }
        paused.compareExchange(expected: true, desired: false, ordering: .sequentiallyConsistent)
        return false
    }

    /// Counts `count` bytes handed to the consumer past the window, never pausing: the producer's last
    /// bytes as its source closes (a pause would have no resume).
    public func producedPastWindow(_ count: Int) {
        outstanding.add(count, ordering: .sequentiallyConsistent)
    }

    /// Counts `count` bytes the consumer took. True when the bytes it holds just fell to
    /// ``resumeAt``: the producer's context calls ``resumeIfDrained()``.
    public func consumed(_ count: Int) -> Bool {
        let (old, new) = outstanding.subtract(count, ordering: .sequentiallyConsistent)
        return old > resumeAt && new <= resumeAt
    }

    /// True when the producer was paused and the consumer has drained the window to ``resumeAt``:
    /// the producer resumes its source now.
    public func resumeIfDrained() -> Bool {
        guard outstanding.load(ordering: .sequentiallyConsistent) <= resumeAt else { return false }
        return paused.compareExchange(expected: true, desired: false, ordering: .sequentiallyConsistent).exchanged
    }

    /// Ends a pause whatever the consumer holds (the producer is closing). True when it was paused:
    /// the producer resumes its source so that it can cancel it.
    public func releasePause() -> Bool {
        paused.compareExchange(expected: true, desired: false, ordering: .sequentiallyConsistent).exchanged
    }
}
