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
    /// Set by ``stop()`` so a reconcile/handleEnded already queued on the @MainActor
    /// (e.g. a transport reconnect that fired `onConnectionStateChanged(.connected)`
    /// just before stop ran) short-circuits even if the connection got resurrected —
    /// makes teardown ordering-independent instead of timing-dependent.
    private var isStopped = false
    private var reconcileInFlight = false
    private var reconcileQueued = false
    /// Set once the view has surfaced at least one real workspace. STICKY for the
    /// coordinator's lifetime (never reset, including across an internal `-CC`
    /// reconnect): the empty-host bootstrap fires only while this is false, so closing
    /// the last session tears the mirror down instead of recreating it. A brand-new
    /// coordinator (a fresh `ssh-tmux` after teardown) starts false and bootstraps.
    private var didEverSurfaceWorkspace = false
    /// Set once we've SENT the bootstrap `new-session` for a session-less host, so it
    /// is a single shot even before the new session surfaces on the next reconcile.
    private var didBootstrapEmptyHost = false
    /// How many empty-host bootstraps we've fired this coordinator's lifetime. Bounds
    /// the re-arm below so a host whose freshly-created session keeps vanishing before
    /// it surfaces (server-side flakiness: the detached shell exits instantly, or tmux
    /// refuses) can't spin `new-session` every reconcile — while still retrying enough
    /// to recover from a one-off failure instead of stranding an empty mirror.
    private var emptyHostBootstrapAttempts = 0
    private static let maxEmptyHostBootstrapAttempts = 3

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
                guard let self else { return }
                if state == .connected {
                    self.scheduleReconcile()
                } else {
                    // The stream dropped. A bootstrap `new-session` that was buffered
                    // but lost before the write flushed (the close-before-flush race)
                    // never reached tmux, so re-arm the one-shot to retry on reconnect.
                    // The sticky `didEverSurfaceWorkspace` still prevents recreating a
                    // session the user closed (it only flips true once a real workspace
                    // surfaced), so this can't resurrect closed work.
                    self.didBootstrapEmptyHost = false
                }
            })
        try conn.start()
        conn.setClientSize(columns: initialCols, rows: initialRows)
        connection = conn
    }

    func stop() {
        isStopped = true
        if let observerToken { connection?.removeObserver(observerToken); self.observerToken = nil }
        connection?.stop()
        connection = nil
    }

    /// Creates a new remote tmux session over the live stream and reconciles, so it
    /// links into the view and appears as a new workspace. No new SSH session.
    func newWorkspace() {
        guard createDetachedSession() else { return }
        scheduleReconcile()
    }

    /// Creates a detached real session over the live stream at the view's size (so it
    /// never flashes at 80x24 before linking). Returns whether the command was sent
    /// (false when not connected or the send was dropped). Shared by ``newWorkspace()``
    /// and the session-less-host bootstrap so the `new-session` flags can't drift.
    @discardableResult
    private func createDetachedSession() -> Bool {
        guard let conn = connection, conn.connectionState == .connected else { return false }
        return conn.send("new-session -d -x \(initialCols) -y \(initialRows)")
    }

    /// Pure gate for the session-less-host bootstrap (unit-testable without tmux/SSH):
    /// create one fresh session ONLY when the plan reports no real session AND this
    /// view has NEVER surfaced a workspace (a true initial attach to a session-less
    /// host) AND we haven't already bootstrapped. The "never surfaced" term is what
    /// prevents recreating a session the user just closed — by then the view HAS
    /// surfaced a workspace, so this returns false and the empty plan falls through to
    /// the normal teardown.
    nonisolated static func shouldBootstrapEmptyHost(
        needsBootstrapSession: Bool,
        everSurfacedWorkspace: Bool,
        alreadyBootstrapped: Bool
    ) -> Bool {
        needsBootstrapSession && !everSurfacedWorkspace && !alreadyBootstrapped
    }

    /// Pure gate for RE-arming the empty-host bootstrap after a session we created
    /// vanished before it ever surfaced (server-side flakiness). Distinct from
    /// ``shouldBootstrapEmptyHost``: it requires `alreadyBootstrapped` (we DID send a
    /// `new-session`) yet STILL sees a session-less host that has never surfaced a
    /// workspace — i.e. our session is gone. Bounded by `attempts < maxAttempts` so a
    /// host that keeps killing the new session can't loop. Like the original gate, the
    /// `!everSurfacedWorkspace` term guarantees this never resurrects a session the
    /// user deliberately closed.
    nonisolated static func shouldReBootstrapVanishedEmptyHost(
        needsBootstrapSession: Bool,
        everSurfacedWorkspace: Bool,
        alreadyBootstrapped: Bool,
        attempts: Int,
        maxAttempts: Int
    ) -> Bool {
        needsBootstrapSession && !everSurfacedWorkspace && alreadyBootstrapped && attempts < maxAttempts
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
        guard !isStopped, let conn = connection, conn.connectionState == .connected else { return }
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
        // The query round-trips above are suspension points; bail if we were stopped
        // (window closed / teardown) meanwhile, so we never apply a plan to a dead view.
        guard !isStopped else { return }

        let snapshot = RemoteTmuxLinkedViewPlan.Snapshot(
            sessions: RemoteTmuxViewSession.parseRows(sessOut.joined(separator: "\n")),
            windows: RemoteTmuxLinkedWorkspaceModel.parseRows(winOut.joined(separator: "\n")),
            cmuxOwnedWindowIds: ownedWindowIds,
            placeholderWindowId: placeholderWindowId)
        let plan = RemoteTmuxLinkedViewPlan.plan(view: view, snapshot: snapshot)

        // Sticky: remember once a real workspace has been surfaced, so the bootstrap
        // below can never recreate a session the user just closed.
        if !plan.workspaces.isEmpty { didEverSurfaceWorkspace = true }

        // Session-less host on initial attach: create ONE fresh real session so the
        // user gets a workspace instead of an empty mirror (the chosen `ssh-tmux`
        // behavior). The gate (`shouldBootstrapEmptyHost`) fires only when the view
        // has NEVER surfaced a workspace — so a host whose last session the user just
        // closed (`didEverSurfaceWorkspace == true`) falls through to the normal
        // teardown below instead of recreating it. Latch `didBootstrapEmptyHost` ONLY
        // on a successful send, so a dropped command (stdin backpressure → reconnect)
        // retries on the next `.connected` reconcile rather than leaving the mirror
        // stuck empty. The new session surfaces as a workspace on the rescheduled
        // reconcile.
        // Re-arm the one-shot if the session we already bootstrapped vanished before it
        // ever surfaced (rare server-side flakiness). Without this the host sits as a
        // stranded empty mirror until the next reconnect; bounded so a host that keeps
        // killing the new session can't spin.
        if Self.shouldReBootstrapVanishedEmptyHost(
            needsBootstrapSession: plan.needsBootstrapSession,
            everSurfacedWorkspace: didEverSurfaceWorkspace,
            alreadyBootstrapped: didBootstrapEmptyHost,
            attempts: emptyHostBootstrapAttempts,
            maxAttempts: Self.maxEmptyHostBootstrapAttempts
        ) {
            didBootstrapEmptyHost = false
        }
        if Self.shouldBootstrapEmptyHost(
            needsBootstrapSession: plan.needsBootstrapSession,
            everSurfacedWorkspace: didEverSurfaceWorkspace,
            alreadyBootstrapped: didBootstrapEmptyHost
        ) {
            if createDetachedSession() {
                didBootstrapEmptyHost = true
                emptyHostBootstrapAttempts += 1
                scheduleReconcile()
            }
            return
        }

        for action in plan.reconcileActions {
            switch action {
            case let .link(windowId):
                if conn.send("link-window -s \(windowId) -t \(quoted(view.sessionName))") {
                    ownedWindowIds.insert(windowId)
                }
            case let .unlinkFromView(windowId):
                // Unlink the view's COPY (by its index in the view), so the real
                // session keeps the window.
                if let idx = snapshot.windows.first(where: {
                    $0.sessionName == view.sessionName && $0.windowId == windowId
                })?.windowIndex {
                    _ = conn.send("unlink-window -t \(quoted(view.sessionName)):\(idx)")
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
        // Idempotent: a stream %exit can arrive after the coordinator was already
        // stopped (window close / explicit teardown), and onEnded must fire at most
        // once (it discards the window).
        guard !isStopped else { return }
        isStopped = true
        workspaces = []
        onEnded?()
    }

    private func quoted(_ v: String) -> String { RemoteTmuxHost.shellSingleQuoted(v) }
}
