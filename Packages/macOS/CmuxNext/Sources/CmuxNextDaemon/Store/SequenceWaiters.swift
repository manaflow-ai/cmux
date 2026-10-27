import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError

/// How a ``DaemonStore/waitApplied(atLeast:since:)`` ended.
public enum AppliedWaitResult: Sendable, Equatable {
    /// The store applied every event up to the sequence.
    case reached
    /// The connection changed first: its events may never apply, and the next connection numbers its own.
    case connectionChanged
    /// The waiting task was cancelled (a caller's deadline).
    case cancelled
}

/// A wait ``DaemonStore/settle(through:since:)`` still had pending when it ended.
public enum DaemonSettleWait: String, Sendable, Equatable, CaseIterable {
    /// The store had not applied every event up to the sequence.
    case applied = "daemon.applied"
    /// An intent was still pending.
    case intents = "daemon.intents"
    /// The connection changed: the sequence can no longer be reached.
    case connection = "daemon.connection"
}

/// The continuations of the store's awaitable waits (``DaemonStore/waitApplied(atLeast:since:)``,
/// ``DaemonStore/waitIntentsIdle()``, ``DaemonStore/waitConnectionChange(since:)``), by id, so a cancelled wait removes its own. Pure bookkeeping:
/// the store resumes them from the state changes that end them.
struct SequenceWaiters {
    struct Applied {
        let sequence: UInt64
        let epoch: Int
        let continuation: OnceContinuation<AppliedWaitResult, OnceContinuationError>
    }

    private var lastID: UInt64 = 0
    private var applied: [UInt64: Applied] = [:]
    private var idle: [UInt64: OnceContinuation<Bool, OnceContinuationError>] = [:]
    private var connection: [UInt64: (epoch: Int, continuation: OnceContinuation<Bool, OnceContinuationError>)] = [:]

    var hasApplied: Bool { !applied.isEmpty }
    var hasIdle: Bool { !idle.isEmpty }
    var count: Int { applied.count + idle.count + connection.count }

    mutating func makeID() -> UInt64 {
        lastID &+= 1
        return lastID
    }

    mutating func addApplied(_ id: UInt64, _ waiter: Applied) { applied[id] = waiter }

    mutating func addIdle(_ id: UInt64, _ continuation: OnceContinuation<Bool, OnceContinuationError>) { idle[id] = continuation }

    mutating func addConnection(_ id: UInt64, epoch: Int, _ continuation: OnceContinuation<Bool, OnceContinuationError>) {
        connection[id] = (epoch, continuation)
    }

    /// Removes and returns the connection waits whose epoch is no longer `epoch`.
    mutating func takeChangedConnection(epoch: Int) -> [OnceContinuation<Bool, OnceContinuationError>] {
        var due: [OnceContinuation<Bool, OnceContinuationError>] = []
        for (id, waiter) in connection where waiter.epoch != epoch {
            due.append(waiter.continuation)
            connection[id] = nil
        }
        return due
    }

    /// Removes and returns the applied waits that are over: their connection changed (`epoch`; checked first: a
    /// later connection's sequence says nothing about this one's), or the store reached their sequence.
    mutating func takeDueApplied(appliedSequence: UInt64, epoch: Int) -> [(OnceContinuation<AppliedWaitResult, OnceContinuationError>, AppliedWaitResult)] {
        var due: [(OnceContinuation<AppliedWaitResult, OnceContinuationError>, AppliedWaitResult)] = []
        for (id, waiter) in applied {
            if waiter.epoch != epoch {
                due.append((waiter.continuation, .connectionChanged))
            } else if appliedSequence >= waiter.sequence {
                due.append((waiter.continuation, .reached))
            } else {
                continue
            }
            applied[id] = nil
        }
        return due
    }

    /// Removes and returns every applied wait.
    mutating func takeAllApplied() -> [OnceContinuation<AppliedWaitResult, OnceContinuationError>] {
        defer { applied = [:] }
        return applied.values.map(\.continuation)
    }

    /// Removes and returns every idle wait.
    mutating func takeIdle() -> [OnceContinuation<Bool, OnceContinuationError>] {
        defer { idle = [:] }
        return Array(idle.values)
    }

    /// Ends the wait `id` as cancelled, when it still waits.
    mutating func cancel(_ id: UInt64) {
        if let waiter = applied.removeValue(forKey: id) { waiter.continuation.resume(returning: .cancelled) }
        if let continuation = idle.removeValue(forKey: id) { continuation.resume(returning: false) }
        if let waiter = connection.removeValue(forKey: id) { waiter.continuation.resume(returning: false) }
    }
}
