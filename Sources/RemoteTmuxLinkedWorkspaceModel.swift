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
    /// `sessionId` is that session's stable tmux id (`$N`, "" if absent) — the
    /// identity that survives a `rename-session`, so the reconciler can tell a
    /// renamed session from a removed + created one.
    struct WindowRow: Equatable {
        let sessionName: String
        let sessionId: String    // stable $id of the listing session ("" if absent)
        let windowId: String     // stable @id
        let windowIndex: Int
        let isActive: Bool

        init(sessionName: String, sessionId: String = "", windowId: String, windowIndex: Int, isActive: Bool = false) {
            self.sessionName = sessionName
            self.sessionId = sessionId
            self.windowId = windowId
            self.windowIndex = windowIndex
            self.isActive = isActive
        }
    }

    /// Format for `list-windows -a -F`. Uses the printable `:` delimiter (like
    /// ``RemoteTmuxSessionListParser``), NOT a control byte: tmux's
    /// `utf8_sanitize()` rewrites non-printable bytes to `_` for non-UTF-8 clients,
    /// which would drop every row. Controlled fields (`session_id` = `$N`,
    /// `window_id` = `@N`, `window_index` = int, `window_active` = 0/1) come
    /// first; the free-text `session_name` is LAST and rejoined from the
    /// remainder so a `:` in a name can't shift fields.
    static let listFormat = "#{session_id}:#{window_id}:#{window_index}:#{window_active}:#{session_name}"

    static func parseRows(_ output: String) -> [WindowRow] {
        RemoteTmuxSessionListParser.splitRows(output, fieldCount: 5).compactMap { f in
            guard let idx = Int(f[2]) else { return nil }
            return WindowRow(
                sessionName: f[4], sessionId: f[0], windowId: f[1], windowIndex: idx, isActive: f[3] == "1")
        }
    }

    /// A workspace = a home session and its windows (tabs) in tmux index order.
    /// `sessionId` is the home session's stable numeric id (`$N` → `N`), or nil
    /// when the rows carried no parseable id; the reconciler uses it to survive
    /// `rename-session` (same id, new name) without destroying the workspace.
    struct Workspace: Equatable {
        let sessionName: String
        let windowIds: [String]   // ordered by window index
        let activeWindowId: String?
        let sessionId: Int?

        init(sessionName: String, windowIds: [String], activeWindowId: String? = nil, sessionId: Int? = nil) {
            self.sessionName = sessionName
            self.windowIds = windowIds
            self.activeWindowId = activeWindowId
            self.sessionId = sessionId
        }
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
        // One pass: each window's home is the lexicographically smallest non-excluded
        // session that contains it (deterministic single home).
        var homeByWindow: [String: String] = [:]
        for r in rows where !excludedSessions.contains(r.sessionName) {
            if let existing = homeByWindow[r.windowId] {
                if r.sessionName < existing { homeByWindow[r.windowId] = r.sessionName }
            } else {
                homeByWindow[r.windowId] = r.sessionName
            }
        }
        // Collect each home session's windows, taking the index from the row that
        // belongs to that home session (not a different session's linked copy) —
        // and that home row's session id, which is the rename-stable identity the
        // reconciler needs (every row of one session carries the same `$N`).
        var bySession: [String: [(idx: Int, id: String, active: Bool)]] = [:]
        var rawIdBySession: [String: String] = [:]
        for r in rows where homeByWindow[r.windowId] == r.sessionName {
            bySession[r.sessionName, default: []].append((r.windowIndex, r.windowId, r.isActive))
            rawIdBySession[r.sessionName] = r.sessionId
        }
        return bySession.keys.sorted().map { name in
            let ordered = bySession[name]!
                .sorted { ($0.idx, $0.id) < ($1.idx, $1.id) }
            let active = ordered.first(where: { $0.active })?.id
            return Workspace(
                sessionName: name,
                windowIds: ordered.map(\.id),
                activeWindowId: active,
                sessionId: rawIdBySession[name].flatMap(RemoteTmuxController.tmuxSessionNumericId))
        }
    }

    /// The set of window ids that SHOULD be linked into the view = every window
    /// that has a real (non-excluded) home session. Fed to the reconciler as
    /// `desiredWindowIds`.
    static func desiredLinkedWindowIds(rows: [WindowRow], excludedSessions: Set<String>) -> Set<String> {
        Set(rows.filter { !excludedSessions.contains($0.sessionName) }.map(\.windowId))
    }
}
