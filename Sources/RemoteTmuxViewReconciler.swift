import Foundation

/// Pure, declarative reconciliation for the remote-tmux **linked-view** transport
/// (the `remoteTmux.linkedView` beta).
///
/// On hosts whose `sshd` caps each connection to one concurrent session
/// (`MaxSessions 1`), cmux cannot open a `tmux -CC` control client per remote
/// session. Instead it attaches ONE control client to a hidden, cmux-owned
/// aggregate **view** session and `link-window`s every mirrored session's windows
/// into it, so all workspaces stream over the single allowed connection.
///
/// Correctness here is a *reconciliation*, never a pile of optimistic
/// `link-window` side effects: given the desired set of windows (the union of the
/// mirrored sessions' windows) and the view's actual contents, this computes the
/// minimal, safe set of link/unlink actions. It is intentionally pure (no I/O, no
/// tmux, no SSH) so the whole policy is unit-testable and deterministic.
///
/// Safety invariants (enforced here, verified by tests):
/// - The view's own placeholder window (created with the view session) is never
///   unlinked — unlinking the last window would kill the view session.
/// - Only windows cmux itself linked (`cmuxOwnedWindowIds`) are ever unlinked. A
///   window cmux did not link (e.g. one a user manually put in the view) is left
///   untouched — cmux never mutates state it does not own.
/// - Output is sorted so a given (desired, actual) pair always yields the same
///   command order (testable, and stable for logging).
enum RemoteTmuxViewReconciler {
    /// One reconciliation step against the view session.
    enum Action: Equatable, CustomStringConvertible {
        /// `link-window -s <windowId> -t <view>`: pull a mirrored window into the view.
        case link(windowId: String)
        /// `unlink-window` the view's copy of `<windowId>`: drop a window cmux
        /// previously linked but that is no longer desired (its session/window is
        /// gone or was closed). The real (home) session keeps the window.
        case unlinkFromView(windowId: String)

        var description: String {
            switch self {
            case .link(let id): return "link(\(id))"
            case .unlinkFromView(let id): return "unlink(\(id))"
            }
        }
    }

    /// Computes the minimal actions to make the view session's contents match
    /// `desiredWindowIds`.
    ///
    /// - Parameters:
    ///   - desiredWindowIds: stable `@id`s of every window that should appear in
    ///     the view (the union across all mirrored source sessions).
    ///   - actualWindowIds: stable `@id`s currently present in the view session
    ///     (from `list-windows -t <view>`), including the placeholder and any
    ///     not-cmux-owned windows.
    ///   - placeholderWindowId: the view's own initial window `@id`, or `nil` if
    ///     cmux has already replaced/closed it. Never unlinked.
    ///   - cmuxOwnedWindowIds: the `@id`s cmux has linked into the view itself.
    ///     Only these are eligible for unlinking; anything else is left untouched.
    /// - Returns: links first (deterministic), then unlinks, each group sorted by id.
    static func actions(
        desiredWindowIds: Set<String>,
        actualWindowIds: Set<String>,
        placeholderWindowId: String?,
        cmuxOwnedWindowIds: Set<String>
    ) -> [Action] {
        // Link every desired window not already present.
        let toLink = desiredWindowIds.subtracting(actualWindowIds)

        // Unlink only windows that (a) are actually present, (b) cmux owns,
        // (c) are no longer desired, and (d) are not the placeholder.
        var unlinkable = actualWindowIds
            .intersection(cmuxOwnedWindowIds)
            .subtracting(desiredWindowIds)
        if let placeholderWindowId {
            unlinkable.remove(placeholderWindowId)
        }

        // Safety net: never empty the view. Unlinking the view's last window kills
        // the view session (and churns the whole mirror). If nothing would link
        // this pass and the unlinks would remove every remaining window, keep the
        // last one linked until a placeholder/new window exists. The live layer
        // also guarantees a placeholder, but the pure policy must not depend on
        // that being accurate (a nil/stale placeholder must still be safe).
        let wouldEmptyView = toLink.isEmpty && actualWindowIds.subtracting(unlinkable).isEmpty
        if wouldEmptyView, let keepAlive = unlinkable.min() {
            unlinkable.remove(keepAlive)
        }

        return toLink.sorted().map { Action.link(windowId: $0) }
            + unlinkable.sorted().map { Action.unlinkFromView(windowId: $0) }
    }

    /// Whether the view currently holds nothing but its placeholder (and/or
    /// nothing) — i.e. no mirrored windows are present, so the dedicated mirror
    /// window has no live workspaces to show.
    static func viewHasNoMirroredWindows(
        actualWindowIds: Set<String>,
        placeholderWindowId: String?
    ) -> Bool {
        var nonPlaceholder = actualWindowIds
        if let placeholderWindowId {
            nonPlaceholder.remove(placeholderWindowId)
        }
        return nonPlaceholder.isEmpty
    }
}
