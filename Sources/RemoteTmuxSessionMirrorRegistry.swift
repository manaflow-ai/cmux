import Foundation

/// Owns the active session→workspace mirrors ``RemoteTmuxController`` tracks,
/// keyed `connectionHash\u{1}session` (see ``RemoteTmuxHost/connectionKey(sessionName:)``),
/// so a host+session is mirrored into at most one cmux workspace.
///
/// Factored out of the controller so the keyed get/set/remove bookkeeping (and the
/// identity reverse-lookup the rename re-key needs) lives behind a small `@MainActor`
/// surface, mirroring ``RemoteTmuxControlConnectionRegistry``. It only tracks the mirror
/// handles; it deliberately does NOT own teardown side effects — callers still
/// `detachObserver()` a removed mirror and sequence connection/window/transport teardown
/// around their own `await` gaps.
@MainActor
final class RemoteTmuxSessionMirrorRegistry {
    private var mirrors: [String: RemoteTmuxSessionMirror] = [:]

    /// The mirror tracked for `key`, if any.
    func mirror(forKey key: String) -> RemoteTmuxSessionMirror? {
        mirrors[key]
    }

    /// Tracks `mirror` under `key` (replacing any existing entry).
    func setMirror(_ mirror: RemoteTmuxSessionMirror, forKey key: String) {
        mirrors[key] = mirror
    }

    /// Removes and returns the mirror for `key`, if any. Callers `detachObserver()` the result.
    @discardableResult
    func removeMirror(forKey key: String) -> RemoteTmuxSessionMirror? {
        mirrors.removeValue(forKey: key)
    }

    /// Whether any tracked mirror belongs to the endpoint `hostHash`
    /// (the shared-master / dedicated-window still-in-use check).
    func hasMirror(forHostHash hostHash: String) -> Bool {
        mirrors.values.contains { $0.host.connectionHash == hostHash }
    }

    /// Every currently-tracked mirror (a snapshot, safe to iterate while mutating the registry).
    func allMirrors() -> [RemoteTmuxSessionMirror] {
        Array(mirrors.values)
    }

    /// Every currently-tracked key/mirror pair (a snapshot, safe to iterate while mutating
    /// the registry). Used where callers remove entries mid-iteration.
    func allEntries() -> [(key: String, mirror: RemoteTmuxSessionMirror)] {
        mirrors.map { (key: $0.key, mirror: $0.value) }
    }

    /// Re-keys `mirror` from `oldKey` to `newKey` after tmux confirms a session
    /// rename. Falls back to an identity reverse-lookup when the mirror is no
    /// longer at `oldKey`, so the entry follows the rename regardless of its current key.
    func rekey(from oldKey: String, to newKey: String, matching mirror: RemoteTmuxSessionMirror) {
        if let existing = mirrors.removeValue(forKey: oldKey) {
            mirrors[newKey] = existing
        } else if let currentKey = mirrors.first(where: { $0.value === mirror })?.key {
            mirrors.removeValue(forKey: currentKey)
            mirrors[newKey] = mirror
        }
    }
}
