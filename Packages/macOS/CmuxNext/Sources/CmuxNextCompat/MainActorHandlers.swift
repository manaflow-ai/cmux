import Foundation

/// The main-actor handlers that one value source calls in turn, kept so that a registration
/// stops on whichever thread releases it.
///
/// A source (Low Power Mode, the kernel's memory pressure) holds one list and calls
/// ``call(_:)`` on the main actor with each new value; every subscriber keeps the
/// ``MainActorHandlerRegistration`` that ``add(_:)`` returns. Releasing or cancelling the
/// registration removes the handler at once, on any thread, so an owner's nonisolated `deinit`
/// needs no main-thread hop and no main-only early return.
///
/// ```swift
/// let handlers = MainActorHandlers<Bool>()
/// observation = handlers.add { [weak self] enabled in self?.apply(enabled) }
/// handlers.call(true) // on the main actor
/// ```
public nonisolated final class MainActorHandlers<Value: Sendable>: Sendable {
    /// Work for one value, on the main actor.
    public typealias Handler = @MainActor @Sendable (Value) -> Void

    // Lock carve-out: removal must be synchronous from a nonisolated deinit on any thread; the
    // critical sections are O(1) dictionary edits and lookups and a key snapshot, and handlers run unlocked.
    private let entries = Mutex<[UUID: Handler]>([:])

    /// Makes an empty list.
    public init() {}

    /// Adds `handler` until the returned registration is released or cancelled.
    ///
    /// - Parameter handler: Main-actor work for each value ``call(_:)`` delivers.
    /// - Returns: The registration; keep it in a stored property.
    public func add(_ handler: @escaping Handler) -> MainActorHandlerRegistration<Value> {
        let id = UUID()
        entries.withLock { $0[id] = handler }
        return MainActorHandlerRegistration(handlers: self, id: id)
    }

    /// Calls every handler registered now with `value`. The handlers run outside the lock, so a
    /// handler may add or cancel a registration: a handler cancelled during the call is skipped if
    /// its turn has not come yet, and a handler added during the call gets the next value. A
    /// cancel or release on another thread that lands while this handler's call is starting may let
    /// that one call through; owners capture themselves weakly, so that call finds nothing to do.
    ///
    /// - Parameter value: The new value.
    @MainActor
    public func call(_ value: Value) {
        for id in entries.withLock({ Array($0.keys) }) {
            guard let handler = entries.withLock({ $0[id] }) else { continue }
            handler(value)
        }
    }

    /// Whether no handler is registered now.
    public var isEmpty: Bool {
        entries.withLock { $0.isEmpty }
    }

    /// Removes the handler `id` (any thread; a second removal does nothing).
    func remove(_ id: UUID) {
        _ = entries.withLock { $0.removeValue(forKey: id) }
    }
}
