import Foundation

/// The pure "brain" of the linked-view coordinator: given a snapshot of the
/// remote tmux server (its sessions + windows) and the view's current contents,
/// it produces everything the live coordinator must do — whether to (re)create the
/// view, which windows to link/unlink, and the resulting workspace grouping.
///
/// Composing the three tested layers (``RemoteTmuxViewSession``,
/// ``RemoteTmuxViewReconciler``, ``RemoteTmuxLinkedWorkspaceModel``) here keeps the
/// live coordinator a thin I/O shell: it gathers snapshots over the single control
/// stream, calls ``plan(...)``, and applies the result. Pure and deterministic so
/// the whole policy stays unit-testable without tmux/SSH.
enum RemoteTmuxLinkedViewPlan {
    struct Snapshot {
        /// `list-sessions -F RemoteTmuxViewSession.listFormat` rows.
        let sessions: [RemoteTmuxViewSession.SessionRow]
        /// `list-windows -a -F RemoteTmuxLinkedWorkspaceModel.listFormat` rows.
        let windows: [RemoteTmuxLinkedWorkspaceModel.WindowRow]
        /// Window ids cmux has itself linked into the view so far (ownership for
        /// safe unlinking). Empty on first plan.
        let cmuxOwnedWindowIds: Set<String>
        /// The view's placeholder window id, if known.
        let placeholderWindowId: String?
    }

    struct Plan: Equatable {
        /// True when no live, current-format, owned view session exists yet and
        /// the coordinator must create one (via `view.createCommands`).
        let needsViewCreate: Bool
        /// Stale same-owner views to garbage-collect (`kill-session`), never
        /// including the current view or any foreign view.
        let staleViewsToKill: [String]
        /// Reconciliation actions to bring the view's contents to the desired set.
        let reconcileActions: [RemoteTmuxViewReconciler.Action]
        /// The resulting cmux workspaces (home session → ordered window ids).
        let workspaces: [RemoteTmuxLinkedWorkspaceModel.Workspace]
    }

    static func plan(view: RemoteTmuxViewSession, snapshot: Snapshot) -> Plan {
        let viewName = view.sessionName

        // View lifecycle: does our current view exist? what stale ones are ours?
        let needsCreate = !snapshot.sessions.contains { view.isOwnView($0) }
        let stale = snapshot.sessions.filter { view.isOwnStaleView($0) }.map(\.name)

        // Desired links = every non-view window with a real home session.
        let desired = RemoteTmuxLinkedWorkspaceModel.desiredLinkedWindowIds(
            rows: snapshot.windows, viewSessionName: viewName)

        // Actual = window ids currently inside the view session.
        let actual = Set(snapshot.windows
            .filter { $0.sessionName == viewName }
            .map(\.windowId))

        let actions = RemoteTmuxViewReconciler.actions(
            desiredWindowIds: desired,
            actualWindowIds: actual,
            placeholderWindowId: snapshot.placeholderWindowId,
            cmuxOwnedWindowIds: snapshot.cmuxOwnedWindowIds)

        let workspaces = RemoteTmuxLinkedWorkspaceModel.workspaces(
            rows: snapshot.windows, viewSessionName: viewName)

        return Plan(
            needsViewCreate: needsCreate,
            staleViewsToKill: stale,
            reconcileActions: actions,
            workspaces: workspaces)
    }
}
