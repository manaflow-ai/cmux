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
/// so the regrouping policy is unit-testable and deterministic.
///
/// Two correctness properties enforced here (hardened after adversarial review):
/// - **All view sessions are excluded**, not just our own — a *foreign* cmux
///   install's `cmux-view-*` session must never be surfaced as a workspace nor
///   have its windows treated as desired. Callers pass the full set of view
///   session names (from `RemoteTmuxViewSession.isAnyView`).
/// - **Each window has exactly one deterministic home.** A window linked into
///   several real sessions is attributed to the lexicographically smallest
///   non-excluded session containing it, so it appears in exactly one workspace
///   and `%output` routing is stable regardless of tmux row order.
enum RemoteTmuxLinkedWorkspaceModel {
    /// One `list-windows -a -F` row. `sessionName` is the session this row is
    /// listed under (a linked window yields one row per session it's in).
    struct WindowRow: Equatable {
        let sessionName: String
        let windowId: String     // stable @id
        let windowIndex: Int
    }

    /// Format for `list-windows -a -F`. Uses the printable `:` delimiter (like
    /// ``RemoteTmuxSessionListParser``), NOT a control byte: tmux's
    /// `utf8_sanitize()` rewrites non-printable bytes to `_` for non-UTF-8 clients,
    /// which would drop every row. Controlled fields (`window_id` = `@N`,
    /// `window_index` = int) come first; the free-text `session_name` is LAST and
    /// rejoined from the remainder so a `:` in a name can't shift fields.
    static let listFormat = "#{window_id}:#{window_index}:#{session_name}"

    private static let fieldDelimiter = ":"

    static func parseRows(_ output: String) -> [WindowRow] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            var line = String(rawLine)
            if line.last == "\r" { line.removeLast() }
            let f = line.components(separatedBy: fieldDelimiter)
            guard f.count >= 3, let idx = Int(f[1]) else { return nil }
            return WindowRow(
                sessionName: f[2...].joined(separator: fieldDelimiter),
                windowId: f[0],
                windowIndex: idx)
        }
    }

    /// A workspace = a home session and its windows (tabs) in tmux index order.
    struct Workspace: Equatable {
        let sessionName: String
        let windowIds: [String]   // ordered by window index
    }

    /// The deterministic home session for a window: the lexicographically smallest
    /// non-excluded session that contains it, or `nil` if it only exists in
    /// excluded (view) sessions. Used both to route `%output` and to assign a
    /// window to exactly one workspace.
    static func homeSession(
        forWindowId id: String,
        rows: [WindowRow],
        excludedSessions: Set<String>
    ) -> String? {
        rows.lazy
            .filter { $0.windowId == id && !excludedSessions.contains($0.sessionName) }
            .map(\.sessionName)
            .min()
    }

    /// Groups rows into workspaces, excluding the given (view) sessions and
    /// assigning each window to exactly one home.
    ///
    /// - Returns: workspaces sorted by session name; each workspace's window ids
    ///   sorted by (windowIndex, windowId) for a stable tab order.
    static func workspaces(rows: [WindowRow], excludedSessions: Set<String>) -> [Workspace] {
        // Resolve each window's single home once (id → home session).
        var homeByWindow: [String: String] = [:]
        for r in rows where !excludedSessions.contains(r.sessionName) {
            if homeByWindow[r.windowId] == nil {
                homeByWindow[r.windowId] = homeSession(
                    forWindowId: r.windowId, rows: rows, excludedSessions: excludedSessions)
            }
        }
        // Collect each home session's windows, taking the index from the row that
        // belongs to that home session (not a different session's linked copy).
        var bySession: [String: [(idx: Int, id: String)]] = [:]
        for r in rows where !excludedSessions.contains(r.sessionName)
            && homeByWindow[r.windowId] == r.sessionName {
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
    /// that has a real (non-excluded) home session. Fed to the reconciler as
    /// `desiredWindowIds`.
    static func desiredLinkedWindowIds(rows: [WindowRow], excludedSessions: Set<String>) -> Set<String> {
        Set(rows.filter { !excludedSessions.contains($0.sessionName) }.map(\.windowId))
    }
}
