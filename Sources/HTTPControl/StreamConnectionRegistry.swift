import CmuxTerminalAccess
import Foundation

/// Tracks every live SSE connection accepted by ``HTTPControlServer``.
///
/// The registry is the seam ``HTTPControlLifecycle`` calls into when
/// the bearer token rotates (Task 1.22 / D2 / spec §16.3): rotating
/// the token must drop every active subscription because every active
/// SSE response was authenticated against the **previous** token.
///
/// One registry instance lives per ``HTTPControlServer`` and is shared
/// by every accepted stream connection. Lookups are by
/// ``ObjectIdentifier(SSEResponder)`` so different subscriptions can
/// share an ``NWConnection`` if a future fan-out path needs it without
/// the registry collapsing them onto a single key.
public final class StreamConnectionRegistry: @unchecked Sendable {
    /// One tracked stream connection.
    public struct Entry: Sendable {
        /// SSE writer for the connection. Held strongly so the
        /// registry can call ``SSEResponder/emitEnd()`` /
        /// ``SSEResponder/close()`` even if the route handler has
        /// already returned.
        public let responder: SSEResponder
        /// Output subscription the responder is draining from. Held
        /// strongly so the subscription's `onCancel` (cap release,
        /// audit close) fires when the registry tears the entry down.
        public let subscription: OutputSubscription
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Adds an entry to the registry. Returns the key the route should
    /// pass to ``remove(_:)`` on connection-state teardown.
    @discardableResult
    public func register(_ entry: Entry) -> ObjectIdentifier {
        let key = ObjectIdentifier(entry.responder)
        lock.lock()
        entries[key] = entry
        lock.unlock()
        return key
    }

    /// Removes the entry with the given key. No-op if absent.
    public func remove(_ key: ObjectIdentifier) {
        lock.lock()
        entries.removeValue(forKey: key)
        lock.unlock()
    }

    /// Number of currently registered entries. Used by tests to assert
    /// the registry tears down after a connection cancel.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Drops every active stream, emitting a terminal ``event: end``
    /// frame, then closing the connection. Subscriptions are cancelled
    /// (so the per-surface cap slot returns).
    ///
    /// Errors raised by ``SSEResponder/emitEnd()`` are swallowed: the
    /// caller (token rotation, server stop) only wants the streams
    /// gone, not a partial wire log.
    public func invalidateAll() async {
        lock.lock()
        let snapshot = Array(entries.values)
        entries.removeAll()
        lock.unlock()
        for entry in snapshot {
            do {
                try await entry.responder.emitEnd()
            } catch {
                // Best-effort — connection may already be dead.
            }
            await entry.responder.close()
            entry.subscription.cancel()
        }
    }
}
