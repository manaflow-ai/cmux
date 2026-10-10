public import Foundation
import Synchronization

/// What one main-actor drain of a ``MainActorLineBatch`` delivers.
public nonisolated struct MainActorLineDrain<Value: Sendable>: Sendable {
    /// The decoded lines since the last drain, in arrival order.
    public var values: [Value]
    /// Lines were dropped because the batch hit its limit: the receiver's
    /// mirror is incomplete and must resync (request a full page, reconnect).
    public var overflowed: Bool
    /// The connection closed after `values`.
    public var closed: Bool
}

/// Hands lines from a socket queue to the main actor with at most ONE
/// main-actor job pending (nightly 3800566557701 hang: one `Task` per line
/// queued an unbounded backlog of full-list refreshes on the main actor).
///
/// Lines decode on the caller's queue. Lines that arrive while a drain is
/// pending join it, so a burst is one main-actor job however fast lines
/// arrive. The batch holds at most `limit` values; past that it drops lines
/// and reports `overflowed`, so memory and main-actor work stay bounded and
/// the receiver resyncs instead. Close travels in the same channel, after
/// the last value, so a drain never runs after the receiver saw the close.
public nonisolated final class MainActorLineBatch<Value: Sendable>: Sendable {
    private nonisolated struct State {
        var values: [Value] = []
        var overflowed = false
        var closed = false
        var scheduled = false
    }

    private let state = Mutex(State())
    private let limit: Int
    private let drain: @MainActor @Sendable (MainActorLineDrain<Value>) -> Void

    /// - Parameters:
    ///   - limit: the most values one drain may carry (default 4096).
    ///   - drain: runs on the main actor with everything since the last drain.
    public init(limit: Int = 4096, drain: @escaping @MainActor @Sendable (MainActorLineDrain<Value>) -> Void) {
        self.limit = max(limit, 1)
        self.drain = drain
    }

    /// Adds one decoded value (any thread).
    public func submit(_ value: Value) {
        let schedule = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            if state.values.count < limit { state.values.append(value) } else { state.overflowed = true }
            return Self.claim(&state)
        }
        if schedule { scheduleDrain() }
    }

    /// Marks the source closed (any thread); later values are ignored.
    public func close() {
        let schedule = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.closed = true
            return Self.claim(&state)
        }
        if schedule { scheduleDrain() }
    }

    private static func claim(_ state: inout State) -> Bool {
        guard !state.scheduled else { return false }
        state.scheduled = true
        return true
    }

    private func scheduleDrain() {
        // task-owner: the batch; at most one pending (the `scheduled` flag), it ends after one drain.
        Task { @MainActor in self.flush() }
    }

    @MainActor
    private func flush() {
        let batch = state.withLock { state -> MainActorLineDrain<Value> in
            defer {
                state.values = []
                state.overflowed = false
                state.scheduled = false
            }
            return MainActorLineDrain(values: state.values, overflowed: state.overflowed, closed: state.closed)
        }
        drain(batch)
    }
}

extension AgentActivityLineConnection {
    /// Starts the connection and delivers its lines to the main actor in
    /// batches (``MainActorLineBatch``): `decode` runs on the connection's
    /// queue, `onDrain` on the main actor with at most one drain pending.
    /// Use this for every long-lived watch; never start a `Task` per line.
    public func start<Value: Sendable>(send: Data, limit: Int = 4096, decode: @escaping @Sendable (Data) -> Value?,
                                       onDrain: @escaping @MainActor @Sendable (MainActorLineDrain<Value>) -> Void) {
        let batch = MainActorLineBatch(limit: limit, drain: onDrain)
        start(send: send, onLine: { line in
            if let value = decode(line) { batch.submit(value) }
        }, onClose: { batch.close() })
    }
}
