public import Foundation

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
///
/// A value with a `key` replaces the pending one with the same key, which
/// leaves its place and the new one joins at the end: a burst of pushes of
/// one chat is one value, and the order against every other value holds. A
/// watch of many busy chats then never overflows on repeats; its every
/// overflow made the turn-state feed read the whole session list again
/// (31 MB on one Mac, 2026-11-11: "im at 100% cpu rn").
public nonisolated final class MainActorLineBatch<Value: Sendable>: Sendable {
    private nonisolated struct State {
        /// The pending values in arrival order; nil where a newer value of its key replaced it.
        var values: [(key: String?, value: Value)?] = []
        /// Where each pending keyed value sits in `values`.
        var slots: [String: Int] = [:]
        /// The pending values not replaced.
        var live = 0
        var overflowed = false
        var closed = false
        var scheduled = false
    }

    private let state = Mutex(State())
    private let limit: Int
    private let key: (@Sendable (Value) -> String?)?
    private let drain: @MainActor @Sendable (MainActorLineDrain<Value>) -> Void

    /// - Parameters:
    ///   - limit: the most values one drain may carry (default 4096).
    ///   - key: a value's key: a later value with the same key replaces it while both are pending.
    ///   - drain: runs on the main actor with everything since the last drain.
    public init(limit: Int = 4096, key: (@Sendable (Value) -> String?)? = nil,
                drain: @escaping @MainActor @Sendable (MainActorLineDrain<Value>) -> Void) {
        self.limit = max(limit, 1)
        self.key = key
        self.drain = drain
    }

    /// Adds one decoded value (any thread).
    public func submit(_ value: Value) {
        let key = key?(value)
        let schedule = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            if let key, let at = state.slots.removeValue(forKey: key) {
                state.values[at] = nil
                state.live -= 1
            }
            if state.live < limit {
                if let key { state.slots[key] = state.values.count }
                state.values.append((key, value))
                state.live += 1
                // Replaced values leave holes: at most as many as the limit before they close up.
                if state.values.count >= 2 * limit { Self.compact(&state) }
            } else {
                state.overflowed = true
            }
            return Self.claim(&state)
        }
        if schedule { scheduleDrain() }
    }

    private static func compact(_ state: inout State) {
        let kept = state.values.compactMap { $0 }
        state.values = kept
        state.slots = [:]
        for (at, entry) in kept.enumerated() {
            if let key = entry.key { state.slots[key] = at }
        }
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
                state.slots = [:]
                state.live = 0
                state.overflowed = false
                state.scheduled = false
            }
            return MainActorLineDrain(values: state.values.compactMap { $0?.value }, overflowed: state.overflowed,
                                      closed: state.closed)
        }
        drain(batch)
    }
}
