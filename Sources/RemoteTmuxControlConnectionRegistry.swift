import Foundation

/// Owns the live `tmux -CC` control connections ``RemoteTmuxController`` multiplexes,
/// keyed by `connectionHash\u{1}session` (see ``RemoteTmuxHost/connectionKey(sessionName:)``),
/// so repeated attach requests for the same endpoint+session reuse the existing connection.
///
/// Factored out of the controller so the keyed get/set/remove bookkeeping (and the
/// identity reverse-lookup the rename re-key needs) lives behind a small `@MainActor`
/// surface, mirroring ``RemoteTmuxTransportRegistry``. It only tracks the connection
/// handles; it deliberately does NOT own teardown side effects — callers still
/// `stop()` a removed connection and sequence `ssh -O exit` around their own `await`
/// gaps.
@MainActor
final class RemoteTmuxControlConnectionRegistry {
    private var connections: [String: RemoteTmuxControlConnection] = [:]

    /// The connection tracked for `key`, if any.
    func connection(forKey key: String) -> RemoteTmuxControlConnection? {
        connections[key]
    }

    /// Tracks `connection` under `key` (replacing any existing entry).
    func setConnection(_ connection: RemoteTmuxControlConnection, forKey key: String) {
        connections[key] = connection
    }

    /// Removes and returns the connection for `key`, if any. Callers `stop()` the result.
    @discardableResult
    func removeConnection(forKey key: String) -> RemoteTmuxControlConnection? {
        connections.removeValue(forKey: key)
    }

    /// Whether any tracked connection belongs to the endpoint `hostHash`
    /// (the shared-master still-in-use check).
    func hasConnection(forHostHash hostHash: String) -> Bool {
        connections.values.contains { $0.host.connectionHash == hostHash }
    }

    /// Every currently-tracked connection.
    func allConnections() -> [RemoteTmuxControlConnection] {
        Array(connections.values)
    }

    /// Drops every tracked connection (does not stop them).
    func removeAll() {
        connections.removeAll()
    }

    /// Re-keys `connection` from `oldKey` to `newKey` after tmux confirms a session
    /// rename. Falls back to an identity reverse-lookup when the connection is no
    /// longer at `oldKey`, so the entry follows the rename regardless of its current key.
    func rekey(from oldKey: String, to newKey: String, matching connection: RemoteTmuxControlConnection) {
        if let existing = connections.removeValue(forKey: oldKey) {
            connections[newKey] = existing
        } else if let currentKey = connections.first(where: { $0.value === connection })?.key {
            connections.removeValue(forKey: currentKey)
            connections[newKey] = connection
        }
    }
}
