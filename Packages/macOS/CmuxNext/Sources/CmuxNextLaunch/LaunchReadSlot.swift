import CmuxNextCompat

/// The hand-off cell between a ``LaunchRead``'s read and its ``LaunchRead/take()``:
/// the lock is held only to move the value in or out, never while the file is read.
final class LaunchReadSlot<Value: Sendable>: Sendable {
    /// Where the read and the take are.
    private enum Phase: Sendable {
        /// The read is queued or running.
        case reading
        case done(Value)
        case taken
    }

    /// What ``claim()`` found.
    enum Claim: Sendable {
        /// The read finished: its value, handed over.
        case value(Value)
        /// The read has not finished: wait for it, then ``takeAfterWait()``.
        case wait
        /// Already taken: read again.
        case taken
    }

    // A compare-and-set over one small enum, from a synchronous window build and the reading
    // block: the lock carve-out (CLAUDE.md), held only to move the value, never across the read.
    private let phase = Mutex(Phase.reading)

    /// The reader's value: kept for the taker.
    func finish(_ value: Value) {
        phase.withLock { phase in
            switch phase {
            case .reading: phase = .done(value)
            case .done, .taken: break
            }
        }
    }

    /// Hands the value over when it is read.
    func claim() -> Claim {
        phase.withLock { phase -> Claim in
            switch phase {
            case .done(let value):
                phase = .taken
                return .value(value)
            case .reading:
                return .wait
            case .taken:
                return .taken
            }
        }
    }

    /// The value, once the waiter's wait for the read returned.
    func takeAfterWait() -> Value? {
        phase.withLock { phase -> Value? in
            guard case .done(let value) = phase else { return nil }
            phase = .taken
            return value
        }
    }

    /// The value when it is read and not taken, leaving it for the taker.
    func peek() -> Value? {
        phase.withLock { phase -> Value? in
            guard case .done(let value) = phase else { return nil }
            return value
        }
    }
}
