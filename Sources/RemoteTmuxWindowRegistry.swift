import Foundation
import CmuxRemoteWorkspace

/// Owns the dedicated-window bookkeeping ``RemoteTmuxController`` uses for the
/// "one cmux window per remote endpoint" mirror mode (Option 1): the host↔window
/// bindings and the in-flight-attach guard set.
///
/// Factored out of the controller so the two-way binding (and its always-paired
/// insert/remove) plus the re-entrant-attach guard live behind one small
/// `@MainActor` surface. ``beginAttach(hostHash:)`` is a synchronous
/// check-and-insert so callers can guard an `await` gap without an extra
/// suspension point.
@MainActor
final class RemoteTmuxWindowRegistry {
    /// ``RemoteTmuxHost/connectionHash`` → the dedicated cmux window mirroring that
    /// endpoint (Option 1).
    private var windowIdByHost: [String: UUID] = [:]
    /// Reverse map: cmux window id → the full host it mirrors (for window-close
    /// detach and new-session-in-window, which need the endpoint's port/identity).
    private var hostByWindowId: [UUID: RemoteTmuxHost] = [:]
    /// Endpoint ``RemoteTmuxHost/connectionHash`` values with an in-flight
    /// `mirrorHostInNewWindow(host:activateWindow:)`, so a re-entrant call across
    /// the `await` gap can't open a second window for the same endpoint.
    private var pendingAttaches: Set<String> = []
    /// Window ids whose pending close was initiated by an explicit close of the
    /// window's LAST remote workspace (a tab/session close), so the close-commit
    /// handler kills the remote session(s) instead of merely detaching. A plain
    /// app-window/quit close never sets this, so it detaches. Set just before
    /// `performClose`, consumed on the (non-vetoed) close commit, and cleared if
    /// the close is vetoed.
    private var killSessionsOnClose: Set<UUID> = []

    /// Returns `true` if `windowId` is a dedicated remote-tmux mirror window.
    /// Used by the session-snapshot path to exclude these windows: a mirror window
    /// needs a live SSH connection and can't be restored from a generic snapshot.
    func isDedicatedWindow(_ windowId: UUID) -> Bool {
        hostByWindowId[windowId] != nil
    }

    /// Binds `host` to its dedicated `windowId` (both directions).
    func bind(host: RemoteTmuxHost, windowId: UUID) {
        windowIdByHost[host.connectionHash] = windowId
        hostByWindowId[windowId] = host
    }

    /// The dedicated window currently bound to `hostHash`, if any (the reuse check).
    func windowId(forHostHash hostHash: String) -> UUID? {
        windowIdByHost[hostHash]
    }

    /// The full host bound to `windowId`, if any (carries port/identity).
    func host(forWindowId windowId: UUID) -> RemoteTmuxHost? {
        hostByWindowId[windowId]
    }

    /// Atomically records an in-flight attach for `hostHash`; returns `false` if one
    /// is already in flight (the re-entrant-attach guard). Synchronous and
    /// non-suspending so it can guard an `await` gap.
    func beginAttach(hostHash: String) -> Bool {
        guard !pendingAttaches.contains(hostHash) else { return false }
        pendingAttaches.insert(hostHash)
        return true
    }

    /// Clears the in-flight-attach marker for `hostHash` (the `defer`).
    func endAttach(hostHash: String) {
        pendingAttaches.remove(hostHash)
    }

    /// Removes the binding for `hostHash` in BOTH directions, returning the window id
    /// that was bound (if any).
    @discardableResult
    func unbind(hostHash: String) -> UUID? {
        guard let windowId = windowIdByHost.removeValue(forKey: hostHash) else { return nil }
        hostByWindowId.removeValue(forKey: windowId)
        return windowId
    }

    /// Removes the binding for `windowId` in BOTH directions.
    func unbind(windowId: UUID) {
        guard let host = hostByWindowId.removeValue(forKey: windowId) else { return }
        windowIdByHost.removeValue(forKey: host.connectionHash)
    }

    /// Marks `windowId`'s impending close as a tab/session close that should kill
    /// the remote session(s) on commit (rather than detach). Set just before
    /// `performClose`; consumed on the close commit, or on a close veto to clear it.
    func markKillSessionsOnClose(windowId: UUID) {
        killSessionsOnClose.insert(windowId)
    }

    /// Consumes the kill-on-close marker for `windowId`, returning `true` if it was
    /// set (the close-commit handler should kill the session(s), not just detach).
    /// Also used on a close veto to clear the marker (the result is ignored there).
    @discardableResult
    func consumeKillSessionsOnClose(windowId: UUID) -> Bool {
        killSessionsOnClose.remove(windowId) != nil
    }

    /// All window ids currently marked for kill-on-close (for the app-terminate path
    /// to honor a tab/session close of a window's last tab before the app exits).
    func windowsMarkedForKillOnClose() -> [UUID] {
        Array(killSessionsOnClose)
    }
}
