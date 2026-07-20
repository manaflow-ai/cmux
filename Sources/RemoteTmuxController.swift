import AppKit
import Foundation
import CmuxSettings
import OSLog

/// Coordinates cmux's mirroring of remote tmux servers.
///
/// Owns one ``RemoteTmuxSSHTransport`` per endpoint (keyed by
/// ``RemoteTmuxHost/connectionHash`` — destination + port + identity) and
/// is the entry point the socket/CLI layer and (later) the UI call into. It is
/// `@MainActor` because it will own sidebar/workspace state as the feature
/// grows; today it performs discovery by delegating to the per-host transport
/// actor.
///
/// Constructed once and held by `AppDelegate` (no global singleton), so it can
/// be reached from the v2 socket dispatcher via `AppDelegate.shared`.
@MainActor
final class RemoteTmuxController {
    typealias MirrorTabActivity = RemoteTmuxMirrorTabActivity

    /// Diagnostic logger (not user-facing) for mirror lifecycle events such as a
    /// ControlMaster that couldn't be confirmed ready before the attach burst.
    nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app", category: "RemoteTmux")

    /// Per-endpoint SSH transports (keyed by ``RemoteTmuxHost/connectionHash``),
    /// owned by ``RemoteTmuxController`` and delegated to for discovery + master teardown.
    let transportRegistry = RemoteTmuxTransportRegistry()

    /// Live `tmux -CC` control connections keyed by `connectionHash\u{1}session`
    /// (see ``connectionKey(host:sessionName:)``), so repeated attach requests for
    /// the same endpoint+session reuse the existing connection.
    private var connectionsByHostSession: [String: RemoteTmuxControlConnection] = [:]
    private var connectionObserverTokensByHostSession: [String: RemoteTmuxControlConnection.ObserverToken] = [:]
    /// Per-session channels scoping a shared multiplexed view connection down to a
    /// single tmux session, keyed like ``connectionsByHostSession``. Non-private so
    /// the ``RemoteTmuxController+Multiplexer`` extension (a separate file) can wire
    /// and tear them down.
    var channelsByHostSession: [String: RemoteTmuxSessionChannel] = [:]

    init() {}

    /// Synchronous read of the `remoteTmux` beta flag for AppKit/socket paths
    /// that run outside the SwiftUI update cycle. Resolves the same catalog key
    /// the settings store persists to, so the catalog stays the single source
    /// of the key, decode, and default. SwiftUI binds via
    /// `@LiveSetting(\.betaFeatures.remoteTmux)`.
    nonisolated static var isEnabled: Bool {
        let key = SettingCatalog().betaFeatures.remoteTmux
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    /// Returns (creating if needed) the transport for a host.
    func transport(for host: RemoteTmuxHost) -> RemoteTmuxSSHTransport {
        transportRegistry.transport(for: host)
    }

    /// Discovers the tmux sessions on a host.
    func listSessions(host: RemoteTmuxHost) async throws -> [RemoteTmuxSession] {
        try await transport(for: host).listSessions()
    }

    /// Tears down a host's shared SSH master (used when removing a host).
    func disconnect(host: RemoteTmuxHost) async {
        await transportRegistry.disconnectMaster(host: host)
    }

    /// Warms and confirms the host's shared SSH ControlMaster before a per-session
    /// `tmux -CC attach` burst (the single shared gate for every bulk-mirror
    /// entrypoint), so the `ControlMaster=auto` attaches ride a ready master instead
    /// of racing to create it on a cold first attach (#6732).
    ///
    /// Fails closed: an unconfirmed master throws rather than firing the burst into
    /// the exact cold-master race the gate prevents. Callers invoke this *before*
    /// creating any session mirrors, so a throw needs no workspace teardown and the
    /// user can re-attach once the master is warm. The common cold start still
    /// returns `true` (the warmup's single-creator open succeeds), so only the
    /// genuinely-unready case is blocked.
    func ensureControlMasterReadyForBurst(host: RemoteTmuxHost) async throws {
        let ready = try await transport(for: host).ensureMasterReady()
        // The warmup's SSH work runs in a shared unstructured task and isn't
        // cancellation-aware, so a caller cancelled meanwhile (e.g. a v2VmCall
        // timeout) only learns of it here — bail before treating not-ready as a hard
        // failure and before the caller's next irreversible step.
        try Task.checkCancellation()
        guard ready else {
            // Log the non-sensitive connection hash, not the SSH destination (which
            // can carry a username / internal host / IP) — keeps collected diagnostics clean.
            Self.logger.warning("remote-tmux: ControlMaster not confirmed ready [\(host.connectionHash, privacy: .public)]; aborting attach burst")
            // `.unreachable` already means "the SSH master could not be opened"; its
            // localized "host unreachable: %@" message takes the destination as detail.
            throw RemoteTmuxError.unreachable(host.destination)
        }
    }

    // MARK: - Control connections (tmux -CC mirroring)

    /// Attaches a `tmux -CC` control connection to `sessionName` on `host`,
    /// reusing an existing live connection for the same host+session.
    @discardableResult
    func attach(
        host: RemoteTmuxHost,
        sessionName: String,
        createIfMissing: Bool = false
    ) throws -> RemoteTmuxControlConnection {
        let key = Self.connectionKey(host: host, sessionName: sessionName)
        if let existing = connectionsByHostSession[key] {
            if !existing.exited { return existing }
            // Replace a dead connection — fully tear down the old one first so
            // its ssh process, stdin fd, stream continuation and ingest task
            // don't leak.
            removeCachedConnection(forKey: key)?.stop()
        }
        let connection = RemoteTmuxControlConnection(
            host: host,
            sessionName: sessionName,
            createIfMissing: createIfMissing
        )
        // Insert only after a successful launch, so a failed `start()` never
        // leaves a dead (never-started, `exited == false`) connection that a
        // later attach would wrongly reuse.
        try connection.start()
        cacheConnection(connection, key: key)
        return connection
    }

    /// Attaches a single control connection and returns success only after tmux has
    /// emitted `%enter`. Before launching the long-lived control stream, run a
    /// BatchMode tmux probe through the shared transport so auth/session failures
    /// are reported synchronously instead of looking like a successful attach.
    func attachControlStreamWhenReady(
        host: RemoteTmuxHost,
        sessionName: String,
        createIfMissing: Bool = false
    ) async throws -> [String]? {
        if let sshArgv = try await preflightControlAttach(
            host: host,
            sessionName: sessionName,
            createIfMissing: createIfMissing
        ) {
            return sshArgv
        }

        let connection = try attach(
            host: host,
            sessionName: sessionName,
            createIfMissing: createIfMissing
        )
        guard await connection.waitUntilConnected() else {
            stopCachedConnectionIfCurrent(connection, host: host, sessionName: sessionName)
            try Task.checkCancellation()
            throw RemoteTmuxError.unreachable("tmux control stream ended before attach for \(host.destination)")
        }
        return nil
    }

    private func stopCachedConnectionIfCurrent(
        _ connection: RemoteTmuxControlConnection,
        host: RemoteTmuxHost,
        sessionName: String
    ) {
        let key = Self.connectionKey(host: host, sessionName: sessionName)
        guard connectionsByHostSession[key] === connection else { return }
        removeCachedConnection(forKey: key)?.stop()
    }

    func cacheConnection(_ connection: RemoteTmuxControlConnection, key: String? = nil) {
        let key = key ?? Self.connectionKey(host: connection.host, sessionName: connection.sessionName)
        connectionsByHostSession[key] = connection
        connectionObserverTokensByHostSession[key] = connection.addObserver(
            onSessionChanged: { [weak self, weak connection] oldName, newName in
                guard let self, let connection else { return }
                self.handleCachedConnectionSessionNameChanged(
                    connection: connection,
                    oldName: oldName,
                    newName: newName
                )
            }
        )
    }

    @discardableResult
    private func removeCachedConnection(forKey key: String) -> RemoteTmuxControlConnection? {
        guard let connection = connectionsByHostSession.removeValue(forKey: key) else { return nil }
        if let token = connectionObserverTokensByHostSession.removeValue(forKey: key) {
            connection.removeObserver(token)
        }
        return connection
    }

    private func handleCachedConnectionSessionNameChanged(
        connection: RemoteTmuxControlConnection,
        oldName: String,
        newName: String
    ) {
        let oldKey = Self.connectionKey(host: connection.host, sessionName: oldName)
        let newKey = Self.connectionKey(host: connection.host, sessionName: newName)
        guard oldKey != newKey else { return }
        if let existing = connectionsByHostSession[newKey], existing !== connection { return }
        if connectionsByHostSession[oldKey] === connection {
            connectionsByHostSession.removeValue(forKey: oldKey)
            connectionsByHostSession[newKey] = connection
            if let token = connectionObserverTokensByHostSession.removeValue(forKey: oldKey) {
                connectionObserverTokensByHostSession[newKey] = token
            }
            return
        }
        guard let currentKey = connectionsByHostSession.first(where: { $0.value === connection })?.key,
              currentKey != newKey else {
            if let token = connectionObserverTokensByHostSession.removeValue(forKey: oldKey) {
                connectionObserverTokensByHostSession[newKey] = token
            }
            return
        }
        connectionsByHostSession.removeValue(forKey: currentKey)
        connectionsByHostSession[newKey] = connection
        if let token = connectionObserverTokensByHostSession.removeValue(forKey: currentKey) {
            connectionObserverTokensByHostSession[newKey] = token
        }
    }

    /// Ensures the requested session is attachable via non-interactive tmux
    /// commands. Returns an auth-required outcome when BatchMode SSH cannot prompt;
    /// returns `nil` when the control stream may be launched.
    private func preflightControlAttach(
        host: RemoteTmuxHost,
        sessionName: String,
        createIfMissing: Bool
    ) async throws -> [String]? {
        let transport = transport(for: host)

        do {
            try await transport.assertMinimumTmuxVersion(checkClientWhenNoServer: createIfMissing)
            let existing = try await transport.runTmux(["has-session", "-t", sessionName])
            if existing.succeeded {
                return nil
            }
            if let sshArgv = Self.authRequiredAttachArgv(host: host, result: existing) {
                return sshArgv
            }

            guard createIfMissing else {
                throw RemoteTmuxError.commandFailed(exitCode: existing.exitCode, stderr: existing.stderr)
            }

            let created = try await transport.runTmux(["new-session", "-d", "-s", sessionName])
            guard created.succeeded else {
                if let sshArgv = Self.authRequiredAttachArgv(host: host, result: created) {
                    return sshArgv
                }
                throw RemoteTmuxError.commandFailed(exitCode: created.exitCode, stderr: created.stderr)
            }
            return nil
        } catch let error as RemoteTmuxError {
            if case .commandFailed(_, let stderr) = error,
               RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr) {
                return host.interactiveAuthInvocation()
            }
            throw error
        }
    }

    // MARK: - Sidebar mirroring (P3, initial increment)

    /// Active session→workspace mirrors keyed `connectionHash\u{1}session`
    /// (see ``connectionKey(host:sessionName:)``).
    var sessionMirrors: [String: RemoteTmuxSessionMirror] = [:]

    /// Multiplexer mode: one shared `tmux -CC` view connection per host (keyed by
    /// ``RemoteTmuxHost/connectionHash``); the per-session channels scoping it live in
    /// ``channelsByHostSession``.
    var multiplexedViewsByHost: [String: RemoteTmuxViewConnection] = [:]
    /// Multiplexer user intents by host: pending kills, deliberate local detaches,
    /// and the one new session that should be selected when it surfaces. The pure
    /// reconciler follows/prunes these by stable session id so name reuse stays safe.
    var multiplexIntentsByHost: [String: RemoteTmuxMultiplexReconciler.Intents] = [:]
    /// The hidden view connection's own `$id` per host. A changed id means the tmux
    /// server restarted and may have reused `$N`s, so all id-scoped intents are stale.
    var viewEpochSessionIdByHost: [String: Int] = [:]

    /// One caller awaiting a specific mirror to surface after it created that
    /// session (the CLI `new-remote-workspace` path).
    struct NewWorkspaceWaiter { let token: UUID; let resume: (UUID?) -> Void }
    /// Waiters keyed by ``connectionKey(host:sessionName:)``. Resolved with the new
    /// workspace id when ``createMirrorWorkspace`` registers that key's mirror, or
    /// nil when the host tears down or the wait deadline elapses.
    var newWorkspaceWaiters: [String: [NewWorkspaceWaiter]] = [:]
    /// Per-waiter deadline tasks, owned here so resolution cancels them exactly once.
    var newWorkspaceTimeoutTasks: [UUID: Task<Void, Never>] = [:]

    /// In-flight attach guards and kill-on-close markers for remote tmux mirrors.
    let windowRegistry = RemoteTmuxWindowRegistry()

    /// The subset of `sessions` not yet mirrored for `host`: stable tmux ids beat
    /// mutable names so bulk discovery can't duplicate mid-rename (#7362, #7365).
    /// Stream-reported ids win; discovery-seeded ids cover the pre-`%enter` gap.
    func unmirroredSessions(_ sessions: [RemoteTmuxSession], host: RemoteTmuxHost) -> [RemoteTmuxSession] {
        let mirrors = sessionMirrors.values.filter { $0.host.connectionHash == host.connectionHash }
        return Self.unmirroredSessions(sessions, mirroredSessionIds: Set(mirrors.compactMap { $0.connection.sessionId ?? $0.seededSessionId }), mirroredNames: Set(mirrors.map(\.sessionName)))
    }

    /// Mirrors each not-yet-mirrored session into `manager` (one failure must not
    /// abort the rest). Applies ``unmirroredSessions(_:host:)`` stable-id de-dup
    /// itself so every bulk entrypoint survives a rename race with raw input.
    func mirrorSessions(_ sessions: [RemoteTmuxSession], host: RemoteTmuxHost, into manager: TabManager) {
        for session in unmirroredSessions(sessions, host: host) {
            do {
                try mirrorSession(host: host, sessionName: session.name, sessionId: Self.tmuxSessionNumericId(session.id), into: manager)
            } catch {
                #if DEBUG
                cmuxDebugLog("remote-tmux: mirror session failed")
                #endif
            }
        }
    }

    /// Mirrors a single tmux session into a new workspace in `tabManager` (idempotent).
    /// `sessionId` seeds discovery's stable id for de-dup before the stream reports it.
    @discardableResult
    func mirrorSession(
        host: RemoteTmuxHost,
        sessionName: String,
        sessionId: Int? = nil,
        into tabManager: TabManager,
        select: Bool = false
    ) throws -> Bool {
        let key = Self.connectionKey(host: host, sessionName: sessionName)
        guard sessionMirrors[key] == nil else { return false }
        // Attach (and start the ssh process) BEFORE creating the workspace, so a
        // failed connection doesn't leave an orphaned empty mirror workspace in
        // the sidebar.
        let connection = try attach(host: host, sessionName: sessionName)
        _ = createMirrorWorkspace(
            host: host,
            sessionName: sessionName,
            sessionId: sessionId,
            connection: connection,
            into: tabManager,
            select: select
        )
        return true
    }

    /// Builds a mirror workspace for one session and registers it. Shared by the GA
    /// dedicated-connection path (``mirrorSession``) and the multiplexer, which passes
    /// a per-session channel as the source instead of a dedicated connection.
    @discardableResult
    func createMirrorWorkspace(
        host: RemoteTmuxHost,
        sessionName: String,
        sessionId: Int?,
        connection: any RemoteTmuxSessionSource,
        into tabManager: TabManager,
        select: Bool
    ) -> RemoteTmuxSessionMirror {
        let key = Self.connectionKey(host: host, sessionName: sessionName)
        let workspace = tabManager.addWorkspace(
            title: sessionName,
            select: select,
            autoWelcomeIfNeeded: false
        )
        workspace.isRemoteTmuxMirror = true
        workspace.remoteTmuxWindowOrderSync = { [weak self, weak workspace] orderedPanelIds, verification in
            guard let self, let workspace else { return false }
            return self.handleMirrorWindowsReordered(
                workspaceId: workspace.id,
                orderedPanelIds: orderedPanelIds,
                verification: verification
            )
        }
        let mirror = RemoteTmuxSessionMirror(
            host: host,
            sessionName: sessionName,
            seededSessionId: sessionId,
            connection: connection,
            tabManager: tabManager,
            workspace: workspace,
            onControlPaneRemoved: TerminalController.remoteTmuxControlPaneRemovalHandler(),
            onControlSurfaceRemoved: TerminalController.remoteTmuxControlSurfaceRemovalHandler()
        )
        sessionMirrors[key] = mirror
        resolveNewWorkspaceWaiters(key: key, workspaceId: workspace.id)
        return mirror
    }

    /// Resolves every `new-remote-workspace` caller awaiting the mirror for `key`
    /// with the workspace id it just surfaced (or nil on teardown), once each,
    /// cancelling their deadline tasks.
    func resolveNewWorkspaceWaiters(key: String, workspaceId: UUID?) {
        guard let waiters = newWorkspaceWaiters.removeValue(forKey: key) else { return }
        for waiter in waiters {
            newWorkspaceTimeoutTasks.removeValue(forKey: waiter.token)?.cancel()
            waiter.resume(workspaceId)
        }
    }

    /// Whether any dedicated control connection is attached to the given host.
    func hasCachedConnection(hostHash: String) -> Bool {
        connectionsByHostSession.values.contains { $0.host.connectionHash == hostHash }
    }

    /// Suspends until the mirror for (`host`, `sessionName`) surfaces (returning its
    /// new workspace id) or `deadline` elapses (returning nil). Event-driven: the
    /// reconcile's ``createMirrorWorkspace`` drains the waiter, so a create over a
    /// warm view pays no polling tick. Resolves inline if the mirror already exists.
    func awaitNewWorkspace(
        host: RemoteTmuxHost, sessionName: String, deadline: Duration
    ) async -> UUID? {
        let key = Self.connectionKey(host: host, sessionName: sessionName)
        if let existing = sessionMirrors[key]?.mirroredWorkspaceId { return existing }
        let token = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UUID?, Never>) in
            newWorkspaceWaiters[key, default: []].append(
                NewWorkspaceWaiter(token: token, resume: { continuation.resume(returning: $0) }))
            newWorkspaceTimeoutTasks[token] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: deadline)
                self?.resolveNewWorkspaceWaiter(key: key, token: token, workspaceId: nil)
            }
        }
    }

    /// Resolves a single waiter (the deadline path) by token, leaving any siblings
    /// on the same key still waiting.
    private func resolveNewWorkspaceWaiter(key: String, token: UUID, workspaceId: UUID?) {
        guard var waiters = newWorkspaceWaiters[key],
              let idx = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: idx)
        newWorkspaceWaiters[key] = waiters.isEmpty ? nil : waiters
        newWorkspaceTimeoutTasks.removeValue(forKey: token)?.cancel()
        waiter.resume(workspaceId)
    }

    /// The destination (ssh alias / `user@host`) of the host whose mirror owns
    /// `workspaceId`, or nil when no mirror maps to it. Mirror workspaces carry
    /// their host only through the session mirror, so per-host UI (origin color)
    /// reads it here.
    func hostDestination(forWorkspaceId workspaceId: UUID) -> String? {
        sessionMirrors.values.first(where: { $0.mirroredWorkspaceId == workspaceId })?.host.destination
    }

    /// The in-flight routed New Workspace request, if any. Tests await it so the
    /// create round trip and mirror creation finish inside the test body.
    private(set) var newSessionRoutingTask: Task<Void, Never>?

    /// How a failed routed New Workspace reaches the user (host, failure detail,
    /// requesting manager). Local creation stays suppressed either way — a mirror
    /// workspace's Cmd+N must not quietly fall back to a local workspace — so the
    /// failure has to be visible. Settable so tests can capture it instead of
    /// presenting an alert.
    lazy var reportNewSessionFailure: (RemoteTmuxHost, String, TabManager) -> Void = {
        [weak self] host, detail, manager in
        self?.presentNewSessionFailureAlert(host: host, detail: detail, manager: manager)
    }

    private func presentNewSessionFailureAlert(host: RemoteTmuxHost, detail: String, manager: TabManager) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.remoteTmux.newSessionFailed.title",
            defaultValue: "Couldn't Create a tmux Session on \(host.destination)"
        )
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = trimmedDetail.isEmpty
            ? String(
                localized: "dialog.remoteTmux.newSessionFailed.message",
                defaultValue: "tmux new-session failed on the remote host. No workspace was created."
            )
            : trimmedDetail
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        if let window = manager.window ?? NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// New Workspace requested in `manager`: when its ACTIVE workspace is a live
    /// session mirror, create a new detached tmux session on that mirror's host and
    /// mirror it into the same manager, returning `true` (the caller suppresses local
    /// creation). `false` — active workspace isn't a mirror — means the caller
    /// creates a plain local workspace. Routes by the ACTIVE workspace's own mirror
    /// (a window routinely holds mirrors from several hosts plus local workspaces).
    @discardableResult
    func handleNewWorkspaceRequested(in manager: TabManager) -> Bool {
        let entries = sessionMirrors.values.map { (host: $0.host, workspaceId: $0.mirroredWorkspaceId) }
        guard let activeTabId = manager.selectedTab?.id,
              let host = Self.newSessionHost(activeTabId: activeTabId, entries: entries) else {
            return false
        }
        // Multiplexer: create the session IN BAND over the shared view stream — a
        // one-shot ssh would need a second channel a single-connection host refuses.
        // The reply carries the new session's name, so exactly that workspace is
        // selected when it surfaces, and a dropped send does nothing (matching the
        // dedicated transport's silent-failure semantics for the same race).
        if let view = multiplexedViewsByHost[host.connectionHash] {
            newSessionRoutingTask = Task { @MainActor in
                guard let name = await view.createWorkspaceReturningName() else { return }
                guard self.multiplexedViewsByHost[host.connectionHash] === view else { return }
                var intents = self.multiplexIntentsByHost[host.connectionHash] ?? .init()
                intents.pendingSelect = .init(sessionName: name, originatingTabId: activeTabId)
                self.storeMultiplexIntents(intents, hostHash: host.connectionHash)
                view.requestReconcile()
            }
            return true
        }
        newSessionRoutingTask = Task { @MainActor in
            do {
                let result = try await self.transport(for: host).runTmux(
                    ["new-session", "-d", "-P", "-F", "#{session_name}"]
                )
                let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard result.succeeded, !name.isEmpty else { return }
                // Revalidate across the ssh round trip: the manager's window may have
                // closed (skip — the detached session is picked up on the next
                // attach), and the user may have moved on (mirror, don't steal focus).
                guard AppDelegate.shared?.windowId(for: manager) != nil else { return }
                let select = manager.selectedTab?.id == activeTabId
                _ = try self.mirrorSession(host: host, sessionName: name, into: manager, select: select)
            } catch {
                // A failed create leaves nothing to mirror; the user can retry.
            }
        }
        return true
    }

    // MARK: - Create / destroy propagation (P5)

    /// A mirrored workspace was renamed → `rename-session` on the remote so the
    /// tmux session name tracks the cmux workspace title.
    func handleMirrorWorkspaceRenamed(workspaceId: UUID, title: String?) {
        guard let name = RemoteTmuxHost.controlModeCommandName(title),
              let entry = sessionMirrors.first(where: { $0.value.mirroredWorkspaceId == workspaceId })
        else { return }
        let mirror = entry.value
        let oldName = mirror.sessionName
        guard name != oldName, mirror.connection.connectionState == .connected else { return }
        // Target by the stable session id when known, so the rename can't race a
        // prior rename's name.
        guard let target = mirror.connection.sessionId.map({ "$\($0)" })
            ?? RemoteTmuxHost.controlModeLineSafeName(oldName).map(RemoteTmuxHost.shellSingleQuoted)
        else { return }
        _ = mirror.connection.send("rename-session -t \(target) \(RemoteTmuxHost.shellSingleQuoted(name))")
        // Do not re-key local state here. tmux can reject a rename (for example
        // duplicate session name); `%session-changed` is the confirmation point.
        // Multiplexed mirrors never receive `%session-changed` (the shared stream's
        // event describes the hidden view session), so nudge a reconcile to observe
        // the confirmed rename instead.
        if isMultiplexed(mirror) {
            multiplexedViewsByHost[mirror.host.connectionHash]?.requestReconcile()
        }
    }

    /// Tmux confirmed that a mirrored session's name changed. This is the single
    /// place that re-keys controller dictionaries keyed by host+session name.
    func handleMirrorSessionNameChanged(
        mirror: RemoteTmuxSessionMirror,
        oldName: String,
        newName: String
    ) {
        guard let safeName = RemoteTmuxHost.controlModeLineSafeName(newName),
              oldName != safeName else {
            return
        }
        let host = mirror.host
        let oldKey = Self.connectionKey(host: host, sessionName: oldName)
        let newKey = Self.connectionKey(host: host, sessionName: safeName)
        if let existing = sessionMirrors[newKey], existing !== mirror { return }
        if let existing = connectionsByHostSession[newKey], existing !== mirror.connection { return }

        mirror.setSessionName(safeName)
        mirror.connection.setSessionName(safeName)
        // Reverse of the cmux→tmux rename push: a remote `rename-session` (or an
        // automatic session rename) re-titles the mirror's sidebar workspace.
        // This updates the workspace title directly (no `rename-session`
        // feedback); see `applySessionNameToWorkspaceTitle`.
        mirror.applySessionNameToWorkspaceTitle(safeName)

        if oldKey != newKey {
            if let entry = sessionMirrors.removeValue(forKey: oldKey) {
                sessionMirrors[newKey] = entry
            } else if let currentKey = sessionMirrors.first(where: { $0.value === mirror })?.key {
                sessionMirrors.removeValue(forKey: currentKey)
                sessionMirrors[newKey] = mirror
            }

        }
    }

    /// A split was requested from a mirrored multi-pane surface → propagate to
    /// tmux `split-window`. The new pane arrives via the resulting
    /// `%layout-change`. Returns `true` if `surfaceId` is a mirror pane (the
    /// caller suppresses the local split).
    func handleMirrorSplitRequested(
        surfaceId: UUID,
        vertical: Bool,
        focusIntent: RemoteTmuxSplitFocusIntent
    ) -> Bool {
        for sessionMirror in sessionMirrors.values {
            if let match = sessionMirror.windowMirror(forSurfaceId: surfaceId) {
                return match.mirror.requestSplit(
                    fromPane: match.tmuxPaneId,
                    vertical: vertical,
                    focusIntent: focusIntent
                )
            }
        }
        return false
    }

    /// Whether `surfaceId` is a pane of a mirrored multi-pane tmux window (used
    /// to keep the context-menu Split items enabled for mirror panes).
    func isMirrorPaneSurface(_ surfaceId: UUID) -> Bool {
        for sessionMirror in sessionMirrors.values {
            if sessionMirror.windowMirror(forSurfaceId: surfaceId) != nil { return true }
        }
        return false
    }

    /// If `surfaceId` is a remote-tmux mirror pane, delivers `text` to that pane as
    /// a tmux paste (`paste-buffer -p`, bracketed iff the real pane has
    /// bracketed-paste mode on) and returns `true`. Lets a pasted/dropped image
    /// path be recognized by the remote app (e.g. claude → `[Image #N]`) instead of
    /// arriving as plain `send-keys`. Only single-line `text` is routed (covers
    /// file/image paths); callers fall back to their normal insertion for empty or
    /// multi-line text, which can't be carried safely on a one-line control command.
    func pasteIntoMirror(surfaceId: UUID, text: String) -> Bool {
        guard !text.isEmpty, !text.contains(where: { $0 == "\n" || $0 == "\r" }) else { return false }
        guard let target = pasteTarget(forSurfaceId: surfaceId) else { return false }
        return target.connection.pastePane(paneId: target.paneId, text: text)
    }

    /// The live control connection + tmux pane id behind a remote-tmux
    /// session-mirror surface, or `nil`.
    private func pasteTarget(forSurfaceId surfaceId: UUID)
        -> (connection: any RemoteTmuxSessionSource, paneId: Int)?
    {
        for sessionMirror in sessionMirrors.values where sessionMirror.connection.connectionState == .connected {
            if let paneId = sessionMirror.paneId(forSurfaceId: surfaceId) {
                return (sessionMirror.connection, paneId)
            }
        }
        return nil
    }

    /// The SSH upload target for a remote-tmux session-mirror surface, or `nil` if
    /// `surfaceId` isn't one. Lets the image-paste path upload a pasted screenshot
    /// to the remote tmux host (and insert the remote path) instead of an
    /// unreadable macOS-local one.
    func remoteUploadTarget(forSurfaceId surfaceId: UUID) -> TerminalRemoteUploadTarget? {
        for sessionMirror in sessionMirrors.values
        where !sessionMirror.connection.exited && sessionMirror.ownsSurface(surfaceId) {
            return .detectedSSH(sessionMirror.host.detectedSSHSession())
        }
        return nil
    }

    /// A mirrored window's tab was renamed → `rename-window` on the remote.
    func handleMirrorWindowRenamed(workspaceId: UUID, panelId: UUID, title: String?) {
        guard let name = RemoteTmuxHost.controlModeCommandName(title),
              let mirror = sessionMirrors.values.first(where: { $0.mirroredWorkspaceId == workspaceId }),
              mirror.connection.connectionState == .connected,
              let windowId = mirror.windowId(forPanel: panelId) else { return }
        _ = mirror.connection.send("rename-window -t @\(windowId) \(RemoteTmuxHost.shellSingleQuoted(name))")
    }

    /// The live session mirror + tmux window id behind a mirrored window-tab, or
    /// `nil` when `panelId` isn't a mirrored window-tab of `workspaceId` with a
    /// live connection. Shared by the kill routing and the close-confirmation
    /// check so the two can never disagree about which tabs route remotely.
    private func mirrorWindowTarget(workspaceId: UUID, panelId: UUID)
        -> (mirror: RemoteTmuxSessionMirror, windowId: Int)?
    {
        guard let mirror = sessionMirrors.values.first(where: { $0.mirroredWorkspaceId == workspaceId }),
              let windowId = mirror.windowId(forPanel: panelId) else { return nil }
        return (mirror, windowId)
    }

    /// Whether the panel is currently a tmux window tab in a mirrored workspace.
    /// This lets non-interactive socket close paths route or reject before they
    /// mark the tab as a forced local close.
    func isMirrorWindowTab(workspaceId: UUID, panelId: UUID) -> Bool {
        mirrorWindowTarget(workspaceId: workspaceId, panelId: panelId) != nil
    }

    /// A tab close was requested in a mirrored workspace → kill that tmux window
    /// on the remote. The local tab is removed when tmux reports `%window-close`,
    /// so the caller should VETO the immediate local close.
    ///
    /// - Returns: `true` if routed to the remote (caller vetoes the local close);
    ///   `false` if there is no live mirror/connection or the panel isn't a
    ///   mirrored window (caller proceeds with the normal local close).
    func handleMirrorTabCloseRequested(workspaceId: UUID, panelId: UUID) -> Bool {
        guard let target = mirrorWindowTarget(workspaceId: workspaceId, panelId: panelId),
              target.mirror.connection.connectionState == .connected else { return false }
        return target.mirror.connection.send("kill-window -t @\(target.windowId)")
    }

    /// ``MirrorTabActivity`` from the subscription-fed cache (≤~1s stale).
    private func mirrorTabActivityFromCache(
        target: (mirror: RemoteTmuxSessionMirror, windowId: Int)
    ) -> MirrorTabActivity {
        let connection = target.mirror.connection
        let order = connection.windowsByID[target.windowId]?.paneIDsInOrder ?? []
        var states: [Int: RemoteTmuxControlConnection.PaneForegroundState] = [:]
        for paneId in order {
            states[paneId] = connection.paneForegroundStates[paneId]
        }
        return Self.mirrorTabActivity(
            states: states, paneOrder: order,
            activePaneId: connection.activePaneByWindow[target.windowId]
        )
    }

    /// The cached activity answer for a mirrored window-tab, or `nil` when
    /// `panelId` isn't a live mirrored window-tab. Used where a round trip
    /// isn't warranted (the always-warn dialog path).
    func cachedMirrorTabActivity(workspaceId: UUID, panelId: UUID) -> MirrorTabActivity? {
        guard let target = mirrorWindowTarget(workspaceId: workspaceId, panelId: panelId) else { return nil }
        return mirrorTabActivityFromCache(target: target)
    }

    /// Live, close-time variant of ``cachedMirrorTabActivity(workspaceId:panelId:)``:
    /// asks tmux NOW (one round trip) instead of trusting the subscription cache,
    /// which tmux only refreshes about once a second — so a command started right
    /// before ⌘W still gets its confirmation, with the fresh command name for the
    /// dialog. Falls back to the cached answer when the query can't run (link
    /// down, reconnecting, target gone). `completion` runs exactly once, on the
    /// main actor.
    func queryMirrorTabActivity(
        workspaceId: UUID, panelId: UUID, completion: @escaping (MirrorTabActivity) -> Void
    ) {
        guard let target = mirrorWindowTarget(workspaceId: workspaceId, panelId: panelId) else {
            completion(MirrorTabActivity(hasActiveCommand: false, activeCommandName: nil))
            return
        }
        // Strong captures: the controller is app-lifetime and the completion
        // fires exactly once (flushed on stream resets), so nothing can leak.
        target.mirror.connection.queryWindowActivity(windowId: target.windowId) { states in
            if let states {
                let connection = target.mirror.connection
                completion(Self.mirrorTabActivity(
                    states: states,
                    paneOrder: connection.windowsByID[target.windowId]?.paneIDsInOrder
                        ?? Array(states.keys).sorted(),
                    activePaneId: connection.activePaneByWindow[target.windowId]
                ))
            } else {
                completion(self.mirrorTabActivityFromCache(target: target))
            }
        }
    }

    /// The remote tmux session ended FOR GOOD (its last window was killed, it was
    /// killed out-of-band, or a reconnect found it gone) — remove the mirror +
    /// connection and close the now-dead workspace. Never
    /// issues a kill (the session is already gone). A transient transport loss does
    /// NOT reach here — the connection reconnects instead. Deliberate detach uses
    /// the same local teardown because it also removes the mirror while preserving
    /// the remote tmux session (#7364).
    func handleSessionEndedRemotely(
        host: RemoteTmuxHost,
        sessionName: String,
        workspaceId: UUID
    ) {
        tearDownMirrorAndCloseWorkspace(host: host, sessionName: sessionName, workspaceId: workspaceId, reason: .sessionEnded)
    }

    /// Removes a mirror + its control connection, then closes the local workspace.
    /// A genuine remote end may instead honor a pending keep-workspace-open intent;
    /// deliberate detach is authoritative and always removes the mirror workspace.
    private func tearDownMirrorAndCloseWorkspace(
        host: RemoteTmuxHost,
        sessionName: String,
        workspaceId: UUID,
        reason: RemoteTmuxMirrorTeardownReason
    ) {
        let key = Self.connectionKey(host: host, sessionName: sessionName)
        // Multiplexed teardown: release the channel only. The shared stream and
        // ControlMaster belong to the host's view — tearing them down here would
        // kill every sibling session's mirror — and an explicit detach must record
        // the intent so the reconcile excludes the session instead of re-creating it.
        if let mirror = sessionMirrors[key], isMultiplexed(mirror) {
            if reason == .explicitDetach { mirror.connection.endSession(kill: false) }
            teardownMultiplexedMirror(key: key)
            if !hostHasLiveMirror(host) { stopMultiplexedHost(host: host) }
            closeDeadMirrorWorkspace(mirror.mirroredWorkspace)
            return
        }
        let mirrorWorkspace = sessionMirrors[key]?.mirroredWorkspace
        if let mirror = sessionMirrors.removeValue(forKey: key) {
            mirror.detachObserver()
        }
        removeCachedConnection(forKey: key)?.stop()
        let hostHasOtherMirrors = sessionMirrors.values.contains(where: { $0.host.connectionHash == host.connectionHash })
        if !hostHasOtherMirrors {
            let hostHasOtherConnections = connectionsByHostSession.values
                .contains { $0.host.connectionHash == host.connectionHash }
            if !hostHasOtherConnections {
                transportRegistry.remove(connectionHash: host.connectionHash)
                RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
            }
        }
        #if DEBUG
        cmuxDebugLog(
            "remote-tmux: teardown hostHasOtherMirrors=\(hostHasOtherMirrors)"
        )
        #endif
        if reason == .sessionEnded,
           (mirrorWorkspace ?? AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?
            .tabs.first(where: { $0.id == workspaceId }))?
            .handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded() == true { return }
        let manager = mirrorWorkspace?.owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
        let workspace = mirrorWorkspace ?? manager?.tabs.first(where: { $0.id == workspaceId })
        if let manager, let workspace {
            switch reason {
            case .sessionEnded:
                // Preserve a usable owning window when the remote disappears.
                // The replacement is local and must not inherit the remote path.
                if manager.tabs.count == 1 {
                    _ = manager.addWorkspace(inheritWorkingDirectory: false, select: false)
                }
                manager.closeWorkspace(workspace)
            case .explicitDetach:
                // Detach is authoritative even for a pinned final mirror. Closing
                // its owning window avoids stranding a blank `--new-window` shell.
                _ = manager.closeWorkspaceNonInteractively(workspace, allowPinned: true)
            }
        }
    }

    /// Detaches any session mirrors whose workspace is in a closing window.
    /// Window close = detach + preserve remote (no kill); pane surfaces are torn
    /// down via `detachObserver`.
    func handleWindowWorkspacesClosed(workspaceIds: [UUID]) {
        let ids = Set(workspaceIds)
        var affectedHosts: [String: RemoteTmuxHost] = [:]
        for (key, mirror) in sessionMirrors {
            guard let workspaceId = mirror.mirroredWorkspaceId, ids.contains(workspaceId) else { continue }
            affectedHosts[mirror.host.connectionHash] = mirror.host
            mirror.connection.endSession(kill: false)
            mirror.detachObserver()
            sessionMirrors.removeValue(forKey: key)
            // Multiplexed mirrors have a channel, not a cached connection — release
            // it so the shared stream's observer slot doesn't leak.
            if let channel = channelsByHostSession.removeValue(forKey: key) {
                channel.releaseMirror()
            } else {
                removeCachedConnection(forKey: key)?.stop()
            }
        }
        // Stop the shared view for any affected host whose sessions all closed (its
        // channels aren't cached connections, so the master-teardown loop below
        // can't see it).
        for (hash, host) in affectedHosts
        where multiplexedViewsByHost[hash] != nil && !hostHasLiveMirror(host) {
            stopMultiplexedHost(host: host)
        }
        // For any host left with no live mirror or connection, close its shared SSH
        // ControlMaster now — the last-session teardown paths already do this, and
        // a window close must too or the master lingers for the full
        // ControlPersist window.
        for (hash, host) in affectedHosts {
            let stillUsed = sessionMirrors.values.contains { $0.host.connectionHash == hash }
                || connectionsByHostSession.values.contains { $0.host.connectionHash == hash }
            if !stillUsed {
                transportRegistry.remove(connectionHash: hash)
                RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
            }
        }
    }

    /// Marks a window's impending close as a tab/session close (kill on commit, not detach).
    func markKillSessionsOnWindowClose(windowId: UUID) { windowRegistry.markKillSessionsOnClose(windowId: windowId) }

    /// Consumes a window's kill-on-close marker; `true` when the committed close should
    /// kill its remote session(s). Also clears it on a close veto.
    @discardableResult
    func consumeKillSessionsOnWindowClose(windowId: UUID) -> Bool { windowRegistry.consumeKillSessionsOnClose(windowId: windowId) }

    /// Window ids marked for kill-on-close — the app-quit deferral gate in `AppDelegate`.
    func windowsMarkedForKillOnClose() -> [UUID] { windowRegistry.windowsMarkedForKillOnClose() }

    /// App-quit path for a tab/session close of a remote window's LAST tab: tears down
    /// each marked window's mirror sessions on the MainActor, then AWAITS killing them
    /// (bounded by `timeout`) so the session is gone before cmux exits. No
    /// `spawnControlMasterExit` — the kill multiplexes over the live master (ControlPersist reaps it).
    func killMarkedSessionsBeforeTerminate(timeout: Duration = .seconds(3)) async {
        var jobs: [(transport: RemoteTmuxSSHTransport, target: String)] = []
        for windowId in windowRegistry.windowsMarkedForKillOnClose() {
            guard windowRegistry.consumeKillSessionsOnClose(windowId: windowId) else { continue }
            let closingWorkspaceIds = Set(AppDelegate.shared?.tabManagerFor(windowId: windowId)?.tabs.map(\.id) ?? [])
            // Multiplexer: kill every home session over the shared stream (a one-shot
            // ssh would be refused on a single-connection host), await the command
            // barrier so the kills land before quit continues, then stop the view.
            let multiplexedHosts = sessionMirrors.values
                .filter { isMultiplexed($0) && $0.mirroredWorkspaceId.map(closingWorkspaceIds.contains) == true }
                .map(\.host)
            var killedHosts = Set<String>()
            for host in multiplexedHosts where killedHosts.insert(host.connectionHash).inserted {
                // Kill ONLY the sessions whose mirrors are in the closing window — a
                // detached-kept-open or dragged-out session is work the user kept.
                let mirrors = sessionMirrors.filter { _, mirror in
                    isMultiplexed(mirror) && mirror.host.connectionHash == host.connectionHash
                        && mirror.mirroredWorkspaceId.map(closingWorkspaceIds.contains) == true
                }
                for (_, mirror) in mirrors { mirror.connection.endSession(kill: true) }
                if let view = multiplexedViewsByHost[host.connectionHash] {
                    await view.awaitCommandBarrier(timeout: timeout.asSeconds)
                }
                for (key, _) in mirrors { teardownMultiplexedMirror(key: key) }
                if !hostHasLiveMirror(host) { stopMultiplexedHost(host: host) }
            }
            let mirrorsInWindow = sessionMirrors.filter { _, mirror in
                mirror.mirroredWorkspaceId.map(closingWorkspaceIds.contains) == true
            }
            for (key, mirror) in mirrorsInWindow {
                let host = mirror.host
                sessionMirrors.removeValue(forKey: key)
                mirror.detachObserver()
                detach(host: host, sessionName: mirror.sessionName)  // removes the connection too
                jobs.append((transport(for: host), mirror.connection.sessionId.map { "$\($0)" } ?? mirror.sessionName))
                if !sessionMirrors.values.contains(where: { $0.host.connectionHash == host.connectionHash }),
                   !connectionsByHostSession.values.contains(where: { $0.host.connectionHash == host.connectionHash }) {
                    transportRegistry.remove(connectionHash: host.connectionHash)
                }
            }
        }
        await RemoteTmuxSSHTransport.killSessions(jobs, timeout: timeout)
    }

    func detachMirrorWorkspaceKeptOpenLocally(workspaceId: UUID) {
        guard let entry = sessionMirrors.first(where: { $0.value.mirroredWorkspaceId == workspaceId }) else { return }
        let host = entry.value.host
        if isMultiplexed(entry.value) {
            entry.value.connection.endSession(kill: false)
            teardownMultiplexedMirror(key: entry.key)
            // The remote session stays alive and stays published by the view —
            // record the detach intent (via endSession) so the next reconcile
            // excludes it instead of re-mirroring what the user detached.
            if !hostHasLiveMirror(host) { stopMultiplexedHost(host: host) }
            return
        }
        sessionMirrors.removeValue(forKey: entry.key)
        entry.value.detachObserver()
        removeCachedConnection(forKey: entry.key)?.stop()
        let hostHasOtherMirrors = sessionMirrors.values.contains { $0.host.connectionHash == host.connectionHash }
        if !hostHasOtherMirrors, !connectionsByHostSession.values.contains(where: { $0.host.connectionHash == host.connectionHash }) { transportRegistry.remove(connectionHash: host.connectionHash); RemoteTmuxSSHTransport.spawnControlMasterExit(host: host) }
    }

    /// User-initiated mirrored workspace close detaches locally and kills the remote session.
    func handleWorkspaceClosed(workspaceId: UUID) {
        guard let entry = sessionMirrors.first(where: { $0.value.mirroredWorkspaceId == workspaceId })
        else { return }
        let mirror = entry.value
        let host = mirror.host
        let sessionName = mirror.sessionName
        // Multiplexer: kill over the shared view stream (a one-shot ssh would be
        // refused on a single-connection host) and let the reconcile confirm.
        // Remove the mirror + channel NOW (matches GA), and — via the channel's
        // end-session intent — mark the session pending-kill so the next reconcile
        // won't re-surface a workspace for it (the session is still published until
        // tmux confirms the kill) and retries the kill if this send is dropped. Do
        // NOT stop the view here: the reconcile drives last-session teardown.
        if isMultiplexed(mirror) {
            mirror.connection.endSession(kill: true)
            teardownMultiplexedMirror(key: entry.key)
            return
        }
        // Kill by the stable session id when known, so a prior rename-session
        // can't leave us targeting a stale name. If the control client already
        // ended (for example after deliberate detach), closing leftover local
        // chrome must not kill the remote session (#7364).
        let killTarget = Self.workspaceCloseKillTarget(
            connectionExited: mirror.connection.exited,
            sessionId: mirror.connection.sessionId,
            sessionName: sessionName
        )
        sessionMirrors.removeValue(forKey: entry.key)
        mirror.detachObserver()
        detach(host: host, sessionName: sessionName)
        let isLastSession = !sessionMirrors.values.contains(where: { $0.host.connectionHash == host.connectionHash })
        let transport = transport(for: host)
        if isLastSession {
            // Drop the transport so a later re-attach builds a fresh one instead of
            // reusing this soon-to-be-dead master.
            transportRegistry.remove(connectionHash: host.connectionHash)
        }
        Task {
            if let killTarget {
                _ = try? await transport.runTmux(["kill-session", "-t", killTarget])
            }
            // Close the master only after any kill-session attempt has used it;
            // `ssh -O exit` first would tear the connection down before the
            // session dies. The no-kill detach cleanup still exits the master here.
            if isLastSession {
                // …and only if no reattach reclaimed this endpoint during the kill
                // round-trip (a concurrent `cmux ssh-tmux` rebuilds on the same
                // ControlPath); this Task is @MainActor so check + exit is atomic.
                let reclaimed = transportRegistry.contains(connectionHash: host.connectionHash)
                    || sessionMirrors.values.contains { $0.host.connectionHash == host.connectionHash }
                    || connectionsByHostSession.values.contains { $0.host.connectionHash == host.connectionHash }
                if !reclaimed {
                    RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
                }
            }
        }
    }

    /// Returns the control connection for a host+session, if attached.
    func connection(host: RemoteTmuxHost, sessionName: String) -> RemoteTmuxControlConnection? { connectionsByHostSession[Self.connectionKey(host: host, sessionName: sessionName)] }
    func sessionMirror(host: RemoteTmuxHost, sessionName: String) -> RemoteTmuxSessionMirror? { sessionMirrors[Self.connectionKey(host: host, sessionName: sessionName)] }

    func sessionMirror(workspaceId: UUID) -> RemoteTmuxSessionMirror? {
        sessionMirrors.values.first { $0.mirroredWorkspaceId == workspaceId }
    }
    /// Detaches a control client and removes its mirror workspace while leaving
    /// the remote session alive (#7364). Internal callers that already removed the
    /// mirror keep the low-level stop-only path, preserving their kill semantics.
    func detach(host: RemoteTmuxHost, sessionName: String) {
        let key = Self.connectionKey(host: host, sessionName: sessionName)
        if let workspaceId = sessionMirrors[key]?.mirroredWorkspaceId {
            tearDownMirrorAndCloseWorkspace(host: host, sessionName: sessionName, workspaceId: workspaceId, reason: .explicitDetach)
            return
        }
        if let mirror = sessionMirrors.removeValue(forKey: key) {
            mirror.detachObserver()
            removeCachedConnection(forKey: key)?.stop()
            let hostHasOtherMirrors = sessionMirrors.values.contains { $0.host.connectionHash == host.connectionHash }
            if !hostHasOtherMirrors,
               !connectionsByHostSession.values.contains(where: { $0.host.connectionHash == host.connectionHash }) {
                transportRegistry.remove(connectionHash: host.connectionHash)
                RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
            }
            return
        }
        removeCachedConnection(forKey: key)?.stop()
    }

    /// Detaches every control connection on app quit and closes the shared SSH
    /// ControlMasters, so quitting cmux closes the ssh connections it opened (the
    /// CLI's `ssh -f` left them persistent). Does NOT kill any remote tmux
    /// server/session — only the local control clients and masters.
    func detachAll() {
        // Stop every shared view stream first — their channels aren't cached
        // connections, so the loop below can't see them.
        for host in multiplexedViewsByHost.values.map(\.host) { stopMultiplexedHost(host: host) }
        let connections = Array(connectionsByHostSession.keys).compactMap { removeCachedConnection(forKey: $0) }
        for connection in connections { connection.stop() }
        // Fire-and-forget `ssh -O exit` per endpoint: it hits the local control
        // socket and runs independently of cmux, so the masters are torn down even as
        // the app exits — no lingering ssh after quit. Collect endpoints from BOTH
        // transports AND control connections (the remote.tmux.attach path opens a
        // ControlPersist master via the connection without ever creating a transport),
        // deduped by connectionHash.
        var hostsByHash: [String: RemoteTmuxHost] = [:]
        for connection in connections { hostsByHash[connection.host.connectionHash] = connection.host }
        for host in transportRegistry.allHosts() { hostsByHash[host.connectionHash] = host }
        transportRegistry.removeAll()
        for host in hostsByHash.values { RemoteTmuxSSHTransport.spawnControlMasterExit(host: host) }
    }

    /// The dictionary key for a control connection / session mirror, scoped to the
    /// full SSH connection identity (``RemoteTmuxHost/connectionHash`` — destination
    /// + port + identity), so the same destination reached on a different port or
    /// with a different identity file never aliases onto another endpoint's
    /// connection.
    static func connectionKey(host: RemoteTmuxHost, sessionName: String) -> String {
        "\(host.connectionHash)\u{1}\(sessionName)"
    }
}
