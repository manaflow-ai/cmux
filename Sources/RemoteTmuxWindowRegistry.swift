import Foundation

/// Owns remote-tmux attach concurrency guards and kill-on-close markers.
///
/// Factored out of the controller so the re-entrant-attach guard lives behind
/// one small `@MainActor` surface. ``beginAttach(hostHash:)`` is a synchronous
/// check-and-insert so callers can guard an `await` gap without an extra
/// suspension point.
@MainActor
final class RemoteTmuxWindowRegistry {
    /// Endpoint ``RemoteTmuxHost/connectionHash`` values with an in-flight
    /// attach, so a re-entrant call across the `await` gap can't duplicate work.
    private var pendingAttaches: Set<String> = []
    /// Window ids whose pending close was initiated by an explicit close of the
    /// window's LAST remote workspace (a tab/session close), so the close-commit
    /// handler kills the remote session(s) instead of merely detaching. A plain
    /// app-window/quit close never sets this, so it detaches. Set just before
    /// `performClose`, consumed on the (non-vetoed) close commit, and cleared if
    /// the close is vetoed.
    private var killSessionsOnClose: Set<UUID> = []

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
