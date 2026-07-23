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
/// 1. `start()` — attach the single `-CC` client with `new-session -A -s <view> -x -y`,
///    which attaches the view when it exists and creates it at the right size when it
///    does not. Nothing runs before it: opening the host costs ONE connection, which is
///    what a transport that authenticates per connection makes visible — every extra
///    channel is another 2FA prompt.
/// 2. On connect / every `%topology` change — `reconcile()` queries the server
///    OVER the control stream (a second one-shot ssh would be refused) and applies
///    link/unlink actions, then publishes the regrouped workspaces. The first reconcile
///    also finishes bringing the view up: it stamps the ownership options, reads the
///    placeholder + already-linked windows, and reaps our own stale views.
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

    /// A parked shared stream needs a login, and the payload is the `ssh` argv to run under a tty.
    ///
    /// One stream carries every session on the host, so one login unblocks all of them — which is
    /// why this is a single host-level callback rather than a per-session fan-out. Returns `true`
    /// only if a login was actually presented; reporting `true` merely for being subscribed would
    /// suppress the connection's retry fallback and strand the host.
    var onAuthRequired: ((_ sshArgv: [String]) -> Bool)?

    private let initialCols: Int
    private let initialRows: Int
    /// Window ids cmux has itself linked into the view (ownership for safe unlink).
    private var ownedWindowIds: Set<String> = []
    private var placeholderWindowId: String?
    /// Whether the over-the-stream view bringup has completed: the ownership options are
    /// stamped (each write acknowledged) and ``placeholderWindowId``/``ownedWindowIds``
    /// have been read back.
    ///
    /// Cleared whenever the stream leaves `.connected`, so the next connect re-runs the
    /// bringup. Server state does survive a transport's own internal reconnect — which
    /// produces no state change here, so the latch holds across it — but a cmux-driven
    /// respawn can find a view that was killed during the outage and recreated empty by
    /// the re-attach. The bringup is three constant option writes plus one query, so
    /// re-running it costs a round trip and removes the dependence on which mode the
    /// reconnect path happens to spawn with.
    private var didBootstrapView = false
    /// Bringup attempts spent since the last connect, so a view that cannot be stamped fails
    /// visibly instead of retrying forever. Reset by a bringup that lands and by a fresh connect.
    private var bringupRetries = 0
    private static let maxBringupRetries = 3
    /// Which bringup attempt the ownership writes below belong to, so a late
    /// acknowledgement from an abandoned attempt cannot answer the current one.
    private var bootstrapAttempt = 0
    /// How many of the current attempt's ownership writes tmux acknowledged with `%end`.
    private var bootstrapWritesAcknowledged = 0
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
    /// Callers awaiting the FIRST non-empty workspace publication (the attach
    /// path). Resolved true on publish, false on end/stop/deadline.
    private var firstWorkspacesWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// Per-waiter deadlines. Owned by the coordinator so stop/publish can cancel
    /// them before resuming the continuation exactly once.
    private var firstWorkspacesTimeoutTasks: [UUID: Task<Void, Never>] = [:]

    init(
        host: RemoteTmuxHost,
        ownerId: String,
        initialCols: Int = 120,
        initialRows: Int = 40
    ) {
        self.host = host
        self.view = RemoteTmuxViewSession(ownerId: ownerId)
        self.initialCols = initialCols
        self.initialRows = initialRows
    }

    // MARK: - Lifecycle

    /// Attaches the single `-CC` client to the view, creating the view in the same command
    /// when the host does not have it yet. Throws if the stream can't launch.
    ///
    /// No pre-attach discovery, and that is the point: the stream opens with no prior
    /// knowledge of the host, so the whole attach is one connection. `new-session -A -s`
    /// is what makes it possible — plain `attach-session` needs the view to exist and
    /// `new-session -t` would create a session grouped with another one's windows.
    ///
    /// Nothing here suspends any more: the view's remaining bringup is queries on the stream
    /// this opens, and those run from the first `reconcile()`.
    func start() throws {
        let conn = RemoteTmuxControlConnection(
            host: host,
            sessionName: view.sessionName,
            attachMode: .attachOrCreateSized(columns: initialCols, rows: initialRows))
        conn.isSharedViewStream = true
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
                    // Re-run the view bringup on the next connect. The view we stamped may
                    // not be the view we come back to: it can be killed during the outage
                    // and recreated by the re-attach, and an unstamped view classifies as
                    // not ours.
                    self.didBootstrapView = false
                    // A fresh connect gets a fresh budget; the old stream's refusals say nothing
                    // about whether this one will take the writes.
                    self.bringupRetries = 0
                }
            },
            onAuthRequired: { [weak self] sshArgv in
                self?.onAuthRequired?(sshArgv) ?? false
            })
        try conn.start()
        conn.setClientSize(columns: initialCols, rows: initialRows)
        connection = conn
    }

    func stop() {
        isStopped = true
        if let observerToken { connection?.removeObserver(observerToken); self.observerToken = nil }
        connection?.unsubscribeSessionDigest()
        // Ask tmux to drop this client before the transport goes away, for the same reason the
        // per-session teardown does: over a transport whose remote half outlives its client, killing
        // the local process leaves the control client attached to the session forever. The view is
        // ONE client for every session on the host, so leaking it here strands the whole host rather
        // than a single mirror. `detachThenStop` degrades to a plain stop when the transport does not
        // need it or the stream is already past `.connected`, so this is safe on every path that
        // stops a view.
        connection?.detachThenStop()
        connection = nil
        resolveFirstWorkspacesWaiters(false)
    }

    /// Suspends until the view publishes its first non-empty workspace set
    /// (resolving immediately when one already exists), the view ends, or
    /// `timeout` elapses — event-driven, so a successful attach never pays a
    /// polling tick, and a slow-but-healthy host isn't misclassified as dead.
    func awaitFirstWorkspaces(timeout: Double) async -> Bool {
        if isStopped { return false }
        if !workspaces.isEmpty { return true }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            if isStopped {
                continuation.resume(returning: false)
                return
            }
            if !workspaces.isEmpty {
                continuation.resume(returning: true)
                return
            }
            firstWorkspacesWaiters[token] = continuation
            firstWorkspacesTimeoutTasks[token] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.nanoseconds(forTimeout: timeout))
                } catch {
                    return
                }
                self?.resolveFirstWorkspaceWaiter(token, published: false)
            }
        }
    }

    private static func nanoseconds(forTimeout timeout: Double) -> UInt64 {
        UInt64(max(0, timeout) * 1_000_000_000)
    }

    private func resolveFirstWorkspaceWaiter(_ token: UUID, published: Bool) {
        firstWorkspacesTimeoutTasks.removeValue(forKey: token)?.cancel()
        firstWorkspacesWaiters.removeValue(forKey: token)?.resume(returning: published)
    }

    private func resolveFirstWorkspacesWaiters(_ published: Bool) {
        guard !firstWorkspacesWaiters.isEmpty || !firstWorkspacesTimeoutTasks.isEmpty else { return }
        let tokens = Set(firstWorkspacesWaiters.keys).union(firstWorkspacesTimeoutTasks.keys)
        for token in tokens { resolveFirstWorkspaceWaiter(token, published: published) }
    }

    /// Creates a detached real session over the live stream and returns its
    /// (auto-assigned) name — so the caller can select exactly that session's
    /// workspace when it surfaces — or nil when the stream is down or the
    /// command failed. Bounded: a slow remote command must not suspend the
    /// caller forever, but this non-reconcile path does not flap the stream.
    func createWorkspaceReturningName(named desiredName: String? = nil) async -> String? {
        guard let conn = connection, conn.connectionState == .connected else { return nil }
        let lines = await conn.queryWithTimeout(
            Self.newSessionCommand(
                cols: initialCols, rows: initialRows, captureName: true, named: desiredName),
            timeout: 10,
            reconnectOnTimeout: false
        )
        guard let name = lines?.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    /// The detached `new-session` command shared by every create path (bootstrap,
    /// GUI New Workspace, CLI `new-remote-workspace`), so their flags can't drift.
    /// `captureName` adds `-P -F '#{session_name}'` when the caller must read the
    /// auto-assigned name back; `named` requests an explicit session name (dropped
    /// if it carries characters tmux forbids in a session name). Created at the
    /// view's size so it never flashes at 80x24 before linking.
    nonisolated static func newSessionCommand(
        cols: Int, rows: Int, captureName: Bool, named: String? = nil
    ) -> String {
        var command = "new-session -d"
        if captureName { command += " -P -F '#{session_name}'" }
        command += " -x \(cols) -y \(rows)"
        if let named, let safe = RemoteTmuxHost.controlModeCommandName(named) {
            command += " -s \(RemoteTmuxHost.shellSingleQuoted(safe))"
        }
        return command
    }

    /// Creates a detached real session over the live stream at the view's size (so it
    /// never flashes at 80x24 before linking). Returns whether the command was sent
    /// (false when not connected or the send was dropped). Shared by ``newWorkspace()``
    /// and the session-less-host bootstrap so the `new-session` flags can't drift.
    @discardableResult
    private func createDetachedSession() -> Bool {
        guard let conn = connection, conn.connectionState == .connected else { return false }
        return conn.send(Self.newSessionCommand(cols: initialCols, rows: initialRows, captureName: false))
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

    /// Kills the given home sessions over the live stream — used on the
    /// quit-with-kill path, where a one-shot ssh would be refused under a
    /// single-connection limit. Scoped to explicit names so sessions the user
    /// detached or moved elsewhere are never collateral. Awaits a bounded
    /// round-trip so the kills land before the caller stops the control
    /// connection. The hidden view session is left for `stop()` to drop.
    func killWorkspaceSessions(named names: [String]) async {
        await killWorkspaceSessions(names.map { RemoteTmuxMultiplexReconciler.SessionRef(name: $0, id: nil) })
    }

    func killWorkspaceSessions(_ refs: [RemoteTmuxMultiplexReconciler.SessionRef]) async {
        guard let conn = connection, conn.connectionState == .connected, !refs.isEmpty else { return }
        for ref in refs {
            guard let target = killTarget(for: ref) else { continue }
            _ = conn.send("kill-session -t \(target)")
        }
        await awaitCommandBarrier(timeout: 3)
    }

    /// Awaits a bounded round-trip after prior in-band mutations. Used on quit so
    /// kill-session writes have reached tmux before the control stream is stopped.
    func awaitCommandBarrier(timeout: Double) async {
        guard let conn = connection, conn.connectionState == .connected else { return }
        _ = await conn.queryWithTimeout(
            "display-message -p ok",
            timeout: timeout,
            reconnectOnTimeout: false
        )
    }

    /// Triggers a reconcile after an out-of-band change the view stream won't notify
    /// on its own — e.g. a new tab is a `new-window` created in a home session that
    /// isn't yet linked into the view, so no `%window-add` arrives on this stream.
    func requestReconcile() { scheduleReconcile() }

    /// Kills one mirrored home session over the live stream and reconciles, so the
    /// coordinator drops its mirror + workspace (and tears down the window when it
    /// was the last). Used by the user-initiated workspace-close path.
    func killWorkspaceSession(named name: String) {
        killWorkspaceSession(RemoteTmuxMultiplexReconciler.SessionRef(name: name, id: nil))
    }

    func killWorkspaceSession(_ ref: RemoteTmuxMultiplexReconciler.SessionRef) {
        guard let conn = connection, conn.connectionState == .connected else { return }
        guard let target = killTarget(for: ref) else { return }
        _ = conn.send("kill-session -t \(target)")
        scheduleReconcile()
    }

    private func killTarget(for ref: RemoteTmuxMultiplexReconciler.SessionRef) -> String? {
        if let id = ref.id { return quoted("$\(id)") }
        // tmux resolves `$`-led targets as ids even when prefixed with `=`, so a
        // nil-id fallback name that starts with `$` is unsafe to send at all.
        guard !ref.name.hasPrefix("$") else { return nil }
        // `=` pins an exact-match: a bare name is a PREFIX match once the session
        // is gone, so a retry for dead "foo" could kill an innocent "foobar".
        return quoted("=" + ref.name)
    }

    // MARK: - View bringup (over the live stream)

    /// Finishes bringing the view up on the stream that just attached it: stamps the
    /// ownership options, then reads the view's windows to recover the placeholder and the
    /// windows a previous cmux run left linked.
    ///
    /// Runs from the first `reconcile()` rather than from `start()` because it needs the
    /// control stream, and `reconcile()` is where the stream's serialization already lives.
    /// Ordering inside one reconcile is what makes it correct: the option writes are
    /// enqueued before that reconcile's `list-sessions`, and tmux answers commands in the
    /// order it received them, so the plan reads a view already tagged as ours.
    ///
    /// The writes are tracked to their `%begin`/`%end` blocks rather than fired and
    /// forgotten, because a write that is dropped or errors while the query still answers
    /// is worse than no bringup at all: the view reads back with `@cmux_view` unset, so it
    /// does not classify as ours, and the same reconcile then links every window into the
    /// view a SECOND time (measured on a live host: window `@18` linked at index 6 and
    /// again at index 8) and offers the session this client is attached to as a stale view
    /// to reap.
    ///
    /// Returns false when a write could not be sent, a write was not acknowledged, or the
    /// window query got no answer — leaving the latch clear so the next reconcile retries
    /// instead of planning against a view that reads as somebody else's.
    private func bootstrapViewOverStream(_ conn: RemoteTmuxControlConnection) async -> Bool {
        bootstrapAttempt += 1
        let attempt = bootstrapAttempt
        bootstrapWritesAcknowledged = 0
        let writes = view.setOptionCommands()
        for command in writes {
            guard conn.sendTracked(command, completion: { [weak self] accepted in
                guard let self, self.bootstrapAttempt == attempt, accepted else { return }
                self.bootstrapWritesAcknowledged += 1
            }) else { return false }
        }
        guard let lines = await reconcileListQuery(
            conn,
            "list-windows -t \(quoted(view.sessionName)) -F '#{window_id} #{window_linked}'"
        ) else { return false }
        // No separate wait for the writes: tmux answers commands in the order it received
        // them, so their blocks have already resolved by the time this reply arrives. A
        // stream that reset in between fails every pending tracked send, which lands here
        // as a missing acknowledgement.
        guard bootstrapWritesAcknowledged == writes.count else { return false }
        let read = Self.readBringupRows(lines)
        placeholderWindowId = read.placeholder
        ownedWindowIds = read.adopted
        return true
    }

    /// Reads the bringup's `list-windows -F '#{window_id} #{window_linked}'` reply into the
    /// placeholder and the windows to treat as ours. Pure, so the row rules can be checked
    /// without a server.
    ///
    /// The placeholder is the window reconcile must never unlink: it is the only window the
    /// view is guaranteed to keep, and unlinking it would destroy the view. It is the
    /// lowest-index window that is NOT linked into another session — `list-windows` is
    /// ordered by index, and every window cmux links in is by definition linked. Index alone
    /// is not enough: `link-window -b` inserts before the target and `base-index` differs
    /// between hosts, so on tmux 3.7 the first row can be a linked copy, which would then be
    /// protected from unlinking while the real placeholder was not. A window whose home
    /// session has died is also unlinked, so this picks it instead when it sits at a lower
    /// index than the placeholder; it would then be left in the view rather than unlinked,
    /// which is the same outcome the previous rule had for the placeholder itself.
    ///
    /// Everything else is adopted as owned, so a view reused from a prior cmux run can have
    /// its dead linked copies unlinked — otherwise they accumulate in the persistent view.
    nonisolated static func readBringupRows(
        _ lines: [String]
    ) -> (placeholder: String?, adopted: Set<String>) {
        let rows = lines.compactMap { line -> (id: String, isLinked: Bool)? in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let id = fields.first, !id.isEmpty else { return nil }
            return (id, fields.count > 1 && fields[1] == "1")
        }
        let placeholder = (rows.first { !$0.isLinked } ?? rows.first)?.id
        var adopted = Set(rows.map(\.id))
        if let placeholder { adopted.remove(placeholder) }
        return (placeholder, adopted)
    }

    /// Kills our own stale views (an older name or format version) over the stream.
    ///
    /// The plan already filters the current view's name out of `staleViewsToKill`, so this
    /// skip is a second line of the same defense rather than the one that holds. It stays
    /// because the cost of being wrong is the whole host — a kill here would take down the
    /// session this client is attached to — and this call site is the one that can name the
    /// live view without any planning at all.
    ///
    /// `=` pins an exact match; a bare name is a prefix match, so reaping `cmux-view-a`
    /// could otherwise take `cmux-view-ab` — a name a second cmux install can hold.
    private func reapStaleViews(_ conn: RemoteTmuxControlConnection, names: [String]) {
        for name in names where name != view.sessionName {
            _ = conn.send("kill-session -t \(quoted("=" + name))")
        }
    }

    // MARK: - Reconcile (over the live stream)

    private func scheduleReconcile() {
        Task { @MainActor in await self.reconcile() }
    }

    /// Re-runs the view bringup after a failure that produced no event to wait on.
    ///
    /// A delay, not a poll: the thing being waited for is a write the stream would not take, and
    /// there is no edge that says it would take one now. Bounded, so a stream that never accepts the
    /// ownership writes stops rather than reconciling in a loop — and `onEnded` still fires if the
    /// stream dies, so giving up here does not strand the host silently.
    private func scheduleBringupRetry() {
        guard !isStopped, bringupRetries < Self.maxBringupRetries else { return }
        bringupRetries += 1
        let attempt = bringupRetries
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250 * attempt))
            guard let self, !self.isStopped, !self.didBootstrapView else { return }
            await self.reconcile()
        }
    }


    private func reconcileListQuery(_ conn: RemoteTmuxControlConnection, _ command: String) async -> [String]? {
        if let first = await conn.queryWithTimeout(command, timeout: 15, reconnectOnTimeout: false) {
            return first
        }
        return await conn.queryWithTimeout(command, timeout: 30, reconnectOnTimeout: true)
    }

    func reconcile() async {
        guard !isStopped, let conn = connection, conn.connectionState == .connected else { return }
        if reconcileInFlight { reconcileQueued = true; return }
        reconcileInFlight = true
        defer {
            reconcileInFlight = false
            if reconcileQueued { reconcileQueued = false; scheduleReconcile() }
        }

        // First reconcile after a connect: finish the view bringup before reading the
        // server, so the queries below see a view tagged as ours and the plan's
        // placeholder/ownership inputs are populated. A bringup that did not fully land
        // returns without applying anything, and the next reconcile retries it.
        if !didBootstrapView {
            guard await bootstrapViewOverStream(conn) else {
                // "The next reconcile retries it" was only true when something else happened to
                // trigger one. A bringup that fails on the SEND — a write the bounded writer
                // refused, a stream that reset mid-batch — produces no topology event and no query
                // timeout, so nothing was scheduled and the view stayed half-initialised with its
                // options unwritten. Ask for one, bounded, because a view that cannot be stamped
                // will not become stampable by asking faster.
                scheduleBringupRetry()
                return
            }
            guard !isStopped else { return }
            didBootstrapView = true
            bringupRetries = 0
        }

        // Bounded: an alive-but-slow server gets one longer retry before we decide
        // the control stream is wedged and reconnect. Other query users opt out of
        // reconnect-on-timeout so quit/new-workspace paths do not flap the stream.
        guard
            let sessOut = await reconcileListQuery(
                conn,
                "list-sessions -F \(quoted(RemoteTmuxViewSession.listFormat))"),
            let winOut = await reconcileListQuery(
                conn,
                "list-windows -a -F \(quoted(RemoteTmuxLinkedWorkspaceModel.listFormat))")
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

        // Garbage-collect the views this owner left behind under a different name or format
        // version. They are ordinary sessions to tmux, so the kill rides the same stream as
        // everything else; the plan already refuses to list a foreign owner's view.
        reapStaleViews(conn, names: plan.staleViewsToKill)

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
            // After the controller callback, so an attach awaiting the first
            // publication resumes with the mirrors already built.
            if !workspaces.isEmpty { resolveFirstWorkspacesWaiters(true) }
        }
    }

    private func handleEnded() {
        // Idempotent: a stream %exit can arrive after the coordinator was already
        // stopped (window close / explicit teardown), and onEnded must fire at most
        // once (it discards the window).
        guard !isStopped else { return }
        isStopped = true
        workspaces = []
        resolveFirstWorkspacesWaiters(false)
        onEnded?()
    }

    private func quoted(_ v: String) -> String { RemoteTmuxHost.shellSingleQuoted(v) }
}

extension Duration {
    /// Seconds as a `Double`, for the timeout parameters that predate `Duration`
    /// (``RemoteTmuxViewConnection/awaitCommandBarrier(timeout:)``,
    /// ``RemoteTmuxControlConnection/queryWithTimeout(_:timeout:reconnectOnTimeout:)``).
    /// Keeps a caller's deadline intact instead of re-hardcoding one at the boundary.
    var asSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
