import Foundation

/// Live coordinator for the linked-view transport (`remoteTmux.linkedView` beta).
///
/// Owns the hidden aggregate view session for one host and drives ONE
/// `tmux -CC` control client attached to it, so every mirrored session's windows
/// stream over the single SSH session a MaxSessions=1 host allows. It is the I/O
/// shell around the tested pure layers: it gathers snapshots and applies the plan
/// produced by ``RemoteTmuxLinkedViewPlan``.
///
/// Lifecycle:
/// 1. `start()` — BEFORE attaching, run sequential one-shots over the shared
///    master (allowed: no `-CC` holds the session yet) to discover existing
///    sessions, garbage-collect our own stale views, and create the owned view at
///    an explicit size. Then attach the single `-CC` client to the view.
/// 2. On connect / every `%topology` change — `reconcile()` queries the server
///    OVER the control stream (a second one-shot ssh would be refused) and applies
///    link/unlink actions, then publishes the regrouped workspaces.
/// 3. `newWorkspace()` — create a detached session over the stream and reconcile,
///    so it links in and surfaces as a new workspace ("new workspace rides the
///    linking").
@MainActor
final class RemoteTmuxViewConnection {
    let host: RemoteTmuxHost
    let view: RemoteTmuxViewSession

    /// The single live `-CC` control connection attached to the view session.
    private(set) var connection: RemoteTmuxControlConnection?
    /// The current regrouped workspaces (home session → ordered window ids).
    private(set) var workspaces: [RemoteTmuxLinkedWorkspaceModel.Workspace] = []
    /// Fires after `workspaces` changes (the controller rebuilds cmux workspaces).
    var onWorkspacesChanged: (() -> Void)?
    /// Fires when the view connection permanently ends.
    var onEnded: (() -> Void)?

    private let transport: RemoteTmuxSSHTransport
    private let initialCols: Int
    private let initialRows: Int
    /// Window ids cmux has itself linked into the view (ownership for safe unlink).
    private var ownedWindowIds: Set<String> = []
    private var placeholderWindowId: String?
    private var observerToken: RemoteTmuxControlConnection.ObserverToken?
    /// Serializes reconciles so overlapping topology events don't interleave.
    private var reconcileInFlight = false
    private var reconcileQueued = false

    init(
        host: RemoteTmuxHost,
        ownerId: String,
        transport: RemoteTmuxSSHTransport,
        initialCols: Int = 120,
        initialRows: Int = 40
    ) {
        self.host = host
        self.view = RemoteTmuxViewSession(ownerId: ownerId)
        self.transport = transport
        self.initialCols = initialCols
        self.initialRows = initialRows
    }

    // MARK: - Lifecycle

    /// Ensures the owned view exists (creating it and GC'ing our stale views via
    /// pre-attach one-shots), then attaches the single `-CC` client and runs the
    /// first reconcile. Throws if the view can't be created or the stream can't attach.
    func start() async throws {
        try await ensureViewSession()
        let conn = RemoteTmuxControlConnection(
            host: host, sessionName: view.sessionName, createIfMissing: false)
        observerToken = conn.addObserver(
            onTopologyChanged: { [weak self] in self?.scheduleReconcile() },
            onExit: { [weak self] in self?.handleEnded() },
            onConnectionStateChanged: { [weak self] state in
                if state == .connected { self?.scheduleReconcile() }
            })
        try conn.start()
        conn.setClientSize(columns: initialCols, rows: initialRows)
        connection = conn
    }

    func stop() {
        if let observerToken { connection?.removeObserver(observerToken); self.observerToken = nil }
        connection?.stop()
        connection = nil
    }

    /// Creates a new remote tmux session over the live stream and reconciles, so it
    /// links into the view and appears as a new workspace. No new SSH session.
    func newWorkspace() {
        guard let conn = connection, conn.connectionState == .connected else { return }
        // Detached, explicit-size so it never flashes at 80x24 before linking.
        _ = conn.send("new-session -d -x \(initialCols) -y \(initialRows)")
        scheduleReconcile()
    }

    /// Kills every mirrored home session over the live stream — used on the
    /// quit-with-kill path, where a one-shot ssh would be refused under
    /// MaxSessions=1. Awaits a round-trip so the kills land before the caller stops
    /// the control connection. The hidden view session is left for `stop()` to drop.
    func killAllWorkspaceSessions() async {
        guard let conn = connection, conn.connectionState == .connected else { return }
        for workspace in workspaces {
            _ = conn.send("kill-session -t \(quoted(workspace.sessionName))")
        }
        // Barrier: the reply only arrives after the server has processed the kills.
        _ = await conn.query("display-message -p ok")
    }

    /// Triggers a reconcile after an out-of-band change the view stream won't notify
    /// on its own — e.g. a new tab is a `new-window` created in a home session that
    /// isn't yet linked into the view, so no `%window-add` arrives on this stream.
    func requestReconcile() { scheduleReconcile() }

    /// Kills one mirrored home session over the live stream and reconciles, so the
    /// coordinator drops its mirror + workspace (and tears down the window when it
    /// was the last). Used by the user-initiated workspace-close path.
    func killWorkspaceSession(named name: String) {
        guard let conn = connection, conn.connectionState == .connected else { return }
        _ = conn.send("kill-session -t \(quoted(name))")
        scheduleReconcile()
    }

    // MARK: - View creation (pre-attach one-shots)

    private func ensureViewSession() async throws {
        // List existing sessions to find our stale views and whether ours exists.
        let listOut = await runOneShot(["list-sessions", "-F", RemoteTmuxViewSession.listFormat])
        let rows = RemoteTmuxViewSession.parseRows(listOut)
        for stale in rows.filter({ view.isOwnStaleView($0) }) {
            _ = await runOneShot(["kill-session", "-t", stale.name])
        }
        if !rows.contains(where: { view.isOwnView($0) }) {
            for argv in view.createArgvs(cols: initialCols, rows: initialRows) {
                _ = await runOneShot(argv)
            }
        }
        // Record the view's placeholder window so reconcile never unlinks it.
        let phOut = await runOneShot(["list-windows", "-t", view.sessionName, "-F", "#{window_id}"])
        let viewWindowIds = phOut
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        placeholderWindowId = viewWindowIds.first
        // Adopt windows already linked into a reused view (from a prior cmux run) as
        // owned, so reconcile can unlink any whose real session has since died —
        // otherwise dead linked copies accumulate in the persistent view session.
        ownedWindowIds = Set(viewWindowIds.dropFirst())
    }

    /// A pre-attach `tmux` one-shot over the shared master, returning stdout (or ""
    /// on failure). Only safe before the `-CC` client attaches (MaxSessions=1).
    private func runOneShot(_ argv: [String]) async -> String {
        (try? await transport.runTmux(argv))?.stdout ?? ""
    }

    // MARK: - Reconcile (over the live stream)

    private func scheduleReconcile() {
        Task { @MainActor in await self.reconcile() }
    }

    func reconcile() async {
        guard let conn = connection, conn.connectionState == .connected else { return }
        if reconcileInFlight { reconcileQueued = true; return }
        reconcileInFlight = true
        defer {
            reconcileInFlight = false
            if reconcileQueued { reconcileQueued = false; scheduleReconcile() }
        }

        guard
            let sessOut = await conn.query("list-sessions -F \(quoted(RemoteTmuxViewSession.listFormat))"),
            let winOut = await conn.query("list-windows -a -F \(quoted(RemoteTmuxLinkedWorkspaceModel.listFormat))")
        else { return }

        let snapshot = RemoteTmuxLinkedViewPlan.Snapshot(
            sessions: RemoteTmuxViewSession.parseRows(sessOut.joined(separator: "\n")),
            windows: RemoteTmuxLinkedWorkspaceModel.parseRows(winOut.joined(separator: "\n")),
            cmuxOwnedWindowIds: ownedWindowIds,
            placeholderWindowId: placeholderWindowId)
        let plan = RemoteTmuxLinkedViewPlan.plan(view: view, snapshot: snapshot)

        for action in plan.reconcileActions {
            switch action {
            case let .link(windowId):
                if conn.send("link-window -s \(windowId) -t \(quoted(view.sessionName))") {
                    ownedWindowIds.insert(windowId)
                }
            case let .unlinkFromView(windowId):
                // Unlink the view's COPY (by its index in the view), so the real
                // session keeps the window. `-k` is required for the case where the
                // home session has since died and the view is the window's ONLY
                // remaining link: tmux refuses a plain `unlink-window` there ("window
                // only linked to one session") and logs a commandError. With `-k` tmux
                // unlinks normally when other links exist, and unlinks+destroys the
                // already-orphaned window when the view is the last link — the correct
                // cleanup either way.
                if let idx = snapshot.windows.first(where: {
                    $0.sessionName == view.sessionName && $0.windowId == windowId
                })?.windowIndex {
                    _ = conn.send("unlink-window -k -t \(quoted(view.sessionName)):\(idx)")
                }
                ownedWindowIds.remove(windowId)
            }
        }

        if plan.workspaces != workspaces {
            workspaces = plan.workspaces
            onWorkspacesChanged?()
        }
    }

    private func handleEnded() {
        workspaces = []
        onEnded?()
    }

    private func quoted(_ v: String) -> String { RemoteTmuxHost.shellSingleQuoted(v) }
}
