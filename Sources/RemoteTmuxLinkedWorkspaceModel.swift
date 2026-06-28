import Foundation

/// Pure mapping from the linked-view's flat window set back to cmux workspaces.
///
/// In linked-view mode a single `tmux -CC` client is attached to the hidden view
/// session, which contains windows linked in from many real sessions. The control
/// stream therefore delivers `%output`/`%window-add` for windows belonging to
/// different home sessions. cmux must regroup them: each real (home) session is a
/// workspace; that session's windows are its tabs, in tmux index order.
///
/// This type turns `list-windows -a` rows into that grouping. It is pure (no tmux)
/// so the regrouping policy is unit-testable and deterministic. A window linked
/// into the view appears under BOTH its home session and the view session; it is
/// always attributed to its home (non-view) session, and the view session itself
/// is never surfaced as a workspace.
enum RemoteTmuxLinkedWorkspaceModel {
    /// One `list-windows -a -F` row. `sessionName` is the session this row is
    /// listed under (a linked window yields one row per session it's in).
    struct WindowRow: Equatable {
        let sessionName: String
        let windowId: String     // stable @id
        let windowIndex: Int
    }

    /// Recommended format for `list-windows -a -F` (session-unit-separated; name last
    /// is not needed since session_name has no separator char here, but we keep a
    /// non-printable separator so window names can't corrupt parsing).
    static let listFormat = "#{session_name}\u{1f}#{window_id}\u{1f}#{window_index}"

    static func parseRows(_ output: String) -> [WindowRow] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count == 3, let idx = Int(f[2]) else { return nil }
            return WindowRow(sessionName: f[0], windowId: f[1], windowIndex: idx)
        }
    }

    /// A workspace = a home session and its windows (tabs) in tmux index order.
    struct Workspace: Equatable {
        let sessionName: String
        let windowIds: [String]   // ordered by window index
    }

    /// Groups rows into workspaces, excluding the view session entirely.
    ///
    /// - Parameters:
    ///   - rows: every `list-windows -a` row for the host's tmux server.
    ///   - viewSessionName: the hidden view session to exclude from workspaces.
    /// - Returns: workspaces sorted by session name; each workspace's window ids
    ///   sorted by (windowIndex, windowId) for a stable tab order. A window that
    ///   only exists in the view (no home session row) is dropped — cmux only ever
    ///   shows windows that have a real home session.
    static func workspaces(rows: [WindowRow], viewSessionName: String) -> [Workspace] {
        // Collect, per home session, its (index, id) windows. Exclude the view.
        var bySession: [String: [(idx: Int, id: String)]] = [:]
        for r in rows where r.sessionName != viewSessionName {
            bySession[r.sessionName, default: []].append((r.windowIndex, r.windowId))
        }
        return bySession.keys.sorted().map { name in
            let ordered = bySession[name]!
                .sorted { ($0.idx, $0.id) < ($1.idx, $1.id) }
                .map(\.id)
            return Workspace(sessionName: name, windowIds: ordered)
        }
    }

    /// The set of window ids that SHOULD be linked into the view = every window
    /// that has a real home session (i.e. all non-view windows). This is the
    /// `desiredWindowIds` fed to ``RemoteTmuxViewReconciler``.
    static func desiredLinkedWindowIds(rows: [WindowRow], viewSessionName: String) -> Set<String> {
        Set(rows.filter { $0.sessionName != viewSessionName }.map(\.windowId))
    }

    /// home session for a given window id (its non-view session), or nil if the
    /// window has no home (view-only) — used to route `%output` to a workspace.
    static func homeSession(forWindowId id: String, rows: [WindowRow], viewSessionName: String) -> String? {
        rows.first { $0.windowId == id && $0.sessionName != viewSessionName }?.sessionName
    }
}
