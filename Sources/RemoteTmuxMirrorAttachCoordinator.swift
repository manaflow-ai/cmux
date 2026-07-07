import Foundation
import OSLog

/// Discovers a remote host's tmux sessions and mirrors them into cmux windows
/// and workspaces: the dedicated-window attach (one cmux window per endpoint),
/// the active-window mirror (`remote.tmux.mirror` socket command), the single
/// per-session workspace mirror, and the "new workspace requested in a dedicated
/// remote window" routing.
///
/// Owned by ``RemoteTmuxController`` and constructed with the controller's shared
/// ``RemoteTmuxWindowRegistry``, ``RemoteTmuxSessionMirrorRegistry`` and
/// ``RemoteTmuxTransportRegistry`` (all reference types), plus the controller's
/// ``RemoteTmuxConnectionCoordinator`` (for the control-connection attach a new
/// mirror needs), so the coordinator reads and re-keys exactly the same live
/// window/mirror/transport/connection state the controller does.
///
/// `@MainActor` because it creates and focuses cmux windows/workspaces through
/// `AppDelegate`/`TabManager` (app-side main-thread state); it holds only the
/// injected registries and the connection coordinator.
@MainActor
final class RemoteTmuxMirrorAttachCoordinator {
    /// Dedicated-window bindings (host↔window) and the in-flight-attach guard,
    /// shared with (and owned by) ``RemoteTmuxController``.
    private let windowRegistry: RemoteTmuxWindowRegistry

    /// Active session→workspace mirrors keyed `connectionHash\u{1}session`,
    /// shared with (and owned by) ``RemoteTmuxController``.
    private let mirrorRegistry: RemoteTmuxSessionMirrorRegistry

    /// Per-endpoint SSH transports (keyed by ``RemoteTmuxHost/connectionHash``),
    /// shared with (and owned by) ``RemoteTmuxController``.
    private let transportRegistry: RemoteTmuxTransportRegistry

    /// Owns the `tmux -CC` control-connection lifecycle; shared with (and owned
    /// by) ``RemoteTmuxController``. Used to attach a control connection before a
    /// session workspace is created.
    private let connectionCoordinator: RemoteTmuxConnectionCoordinator

    init(
        windowRegistry: RemoteTmuxWindowRegistry,
        mirrorRegistry: RemoteTmuxSessionMirrorRegistry,
        transportRegistry: RemoteTmuxTransportRegistry,
        connectionCoordinator: RemoteTmuxConnectionCoordinator
    ) {
        self.windowRegistry = windowRegistry
        self.mirrorRegistry = mirrorRegistry
        self.transportRegistry = transportRegistry
        self.connectionCoordinator = connectionCoordinator
    }

    /// Warms and confirms the host's shared SSH ControlMaster before a per-session
    /// `tmux -CC attach` burst (the single shared gate for every bulk-mirror
    /// entrypoint), so the `ControlMaster=auto` attaches ride a ready master instead
    /// of racing to create it on a cold first attach (#6732).
    ///
    /// Fails closed: an unconfirmed master throws rather than firing the burst into
    /// the exact cold-master race the gate prevents. Callers invoke this *before*
    /// creating the dedicated window, so a throw needs no teardown and the user can
    /// re-attach once the master is warm. The common cold start still returns `true`
    /// (the warmup's single-creator open succeeds), so only the genuinely-unready
    /// case is blocked.
    private func ensureControlMasterReadyForBurst(host: RemoteTmuxHost) async throws {
        let ready = try await transportRegistry.transport(for: host).ensureMasterReady()
        // The warmup's SSH work runs in a shared unstructured task and isn't
        // cancellation-aware, so a caller cancelled meanwhile (e.g. a v2VmCall
        // timeout) only learns of it here — bail before treating not-ready as a hard
        // failure and before the caller's next irreversible step.
        try Task.checkCancellation()
        guard ready else {
            // Log the non-sensitive connection hash, not the SSH destination (which
            // can carry a username / internal host / IP) — keeps collected diagnostics clean.
            RemoteTmuxController.logger.warning("remote-tmux: ControlMaster not confirmed ready [\(host.connectionHash, privacy: .public)]; aborting attach burst")
            // `.unreachable` already means "the SSH master could not be opened"; its
            // localized "host unreachable: %@" message takes the destination as detail.
            throw RemoteTmuxError.unreachable(host.destination)
        }
    }

    /// Opens a NEW cmux window dedicated to `host` and mirrors every tmux session
    /// on it 1:1 (each session a workspace, each window a tab). This keeps remote
    /// work in its own window so the user's local windows are untouched.
    ///
    /// Closing that window only *detaches* (the remote tmux server stays alive
    /// for resume); closing an individual session workspace kills that session.
    /// Reuses (and focuses) the existing dedicated window if one is already open
    /// for the host.
    ///
    /// - Parameters:
    ///   - host: the remote SSH destination.
    ///   - activateWindow: when `true` (user-initiated attach), the new window is
    ///     activated/focused.
    /// - Returns: ``RemoteTmuxAttachOutcome/mirrored(windowId:)`` once the host's
    ///   sessions are mirrored into the dedicated (or reused) window, or
    ///   ``RemoteTmuxAttachOutcome/authRequired(sshArgv:)`` when the host needs
    ///   interactive authentication — in which case **no window is created** and
    ///   the caller (the `cmux ssh-tmux` CLI) runs `sshArgv` in the user's terminal to
    ///   open the shared master, then retries.
    /// - Throws: ``RemoteTmuxError`` if the host is unreachable or has no tmux
    ///   sessions (no empty dedicated window is created in that case).
    @discardableResult
    func mirrorHostInNewWindow(
        host: RemoteTmuxHost,
        activateWindow: Bool = true
    ) async throws -> RemoteTmuxAttachOutcome {
        guard let appDelegate = AppDelegate.shared else {
            throw RemoteTmuxError.unreachable("app not ready")
        }
        // Reuse the dedicated window if this host is already mirrored.
        if let existing = windowRegistry.windowId(forHostHash: host.connectionHash),
           let window = appDelegate.windowForMainWindowId(existing) {
            if activateWindow { window.makeKeyAndOrderFront(nil) }
            let sessions: [RemoteTmuxSession]
            do {
                sessions = try await transportRegistry.transport(for: host).discoverMirrorSessions(createIfEmpty: false)
            } catch let error as RemoteTmuxError {
                if case .commandFailed(_, let stderr) = error,
                   RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr) {
                    return .authRequired(sshArgv: host.interactiveAuthInvocation())
                }
                throw error
            }
            guard try await mirrorUnmirroredSessionsIntoDedicatedWindow(host: host, windowId: existing, sessions: sessions) else {
                throw RemoteTmuxError.unreachable("dedicated window closed during attach for \(host.destination)")
            }
            return .mirrored(windowId: existing)
        }
        // Guard the await gap: a second concurrent attach for the same host must
        // not open a second window.
        guard windowRegistry.beginAttach(hostHash: host.connectionHash) else {
            throw RemoteTmuxError.unreachable("already attaching \(host.destination)")
        }
        defer { windowRegistry.endAttach(hostHash: host.connectionHash) }

        // Discover the host's sessions over the shared ControlMaster (BatchMode, no
        // prompt). A key/agent host — or one with an already-live master — succeeds
        // here and mirrors directly, with no interactive step, so it also works from
        // non-tty callers (scripts). A host that needs interactive auth fails here
        // (BatchMode can't prompt); classify recoverable stderr via
        // ``RemoteTmuxSSHTransport/indicatesInteractiveRetryWillHelp`` and hand back
        // the interactive `ssh` argv so the `cmux ssh-tmux` CLI authenticates in the
        // user's terminal and retries on the now-open master. `transport.run()` creates
        // the control-socket dir, so the returned auth `ssh` can open the master. No
        // window has been created yet — nothing to tear down here. Both discovery calls
        // (including the create-then-relist for an empty server) are inside the catch so
        // a recoverable failure on any preflight/discovery command is classified uniformly.
        let sessions: [RemoteTmuxSession]
        do {
            sessions = try await transportRegistry.transport(for: host).discoverMirrorSessions(createIfEmpty: true)
        } catch let error as RemoteTmuxError {
            if case .commandFailed(_, let stderr) = error,
               RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr) {
                return .authRequired(sshArgv: host.interactiveAuthInvocation())
            }
            throw error
        }
        // Never open an empty dedicated window.
        guard !sessions.isEmpty else {
            throw RemoteTmuxError.unreachable("no tmux sessions on \(host.destination)")
        }
        // Re-check reuse: a concurrent caller may have finished while we awaited.
        if let existing = windowRegistry.windowId(forHostHash: host.connectionHash),
           let window = appDelegate.windowForMainWindowId(existing) {
            if activateWindow { window.makeKeyAndOrderFront(nil) }
            guard try await mirrorUnmirroredSessionsIntoDedicatedWindow(host: host, windowId: existing, sessions: sessions) else {
                throw RemoteTmuxError.unreachable("dedicated window closed during attach for \(host.destination)")
            }
            return .mirrored(windowId: existing)
        }

        // Bail before creating a window the caller has abandoned. The socket handler
        // runs this under a v2VmCall timeout that cancels the task on expiry, but the
        // SSH discovery awaits above are not cancellation-aware — a slow-but-successful
        // probe could otherwise land here after the caller already received a timeout
        // and open an orphaned dedicated window (with live SSH/tmux behind it).
        try Task.checkCancellation()

        // Warm + confirm the shared ControlMaster before creating the window and
        // firing the attach burst below. Doing it pre-window means a not-ready
        // failure (or cancellation) throws here and leaks no orphaned window.
        try await ensureControlMasterReadyForBurst(host: host)

        let windowId = appDelegate.createMainWindow(shouldActivate: activateWindow)
        guard let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            throw RemoteTmuxError.unreachable("could not create window")
        }
        windowRegistry.bind(host: host, windowId: windowId)

        let bootstrapWorkspaceId = manager.tabs.first?.id
        mirrorSessions(sessions, host: host, into: manager)
        // Avoid binding an empty dedicated window when sessions failed or were
        // already mirrored elsewhere; the next attach must be able to retry.
        let newWindowWorkspaceIds = Set(manager.tabs.map(\.id))
        let newWindowHasMirrorForHost = mirrorRegistry.allMirrors().contains { mirror in
            mirror.host.connectionHash == host.connectionHash
                && mirror.mirroredWorkspaceId.map(newWindowWorkspaceIds.contains) == true
        }
        guard newWindowHasMirrorForHost else {
            windowRegistry.unbind(hostHash: host.connectionHash)
            transportRegistry.remove(connectionHash: host.connectionHash)
            RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
            appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId)
            throw RemoteTmuxError.unreachable("could not mirror any tmux session on \(host.destination)")
        }
        // Remove the window's bootstrap (local welcome) workspace once at least
        // one remote workspace exists, so the window is a clean 1:1 mirror.
        if let bootstrapWorkspaceId,
           manager.tabs.count > 1,
           let bootstrap = manager.tabs.first(where: { $0.id == bootstrapWorkspaceId }),
           !bootstrap.isRemoteTmuxMirror {
            manager.closeWorkspace(bootstrap, recordHistory: false)
        }
        return .mirrored(windowId: windowId)
    }

    /// Discovers every tmux session on `host` and mirrors each as its own
    /// sidebar workspace (Option 2 — used by the `remote.tmux.mirror` socket
    /// command). Mirrors into the host's dedicated mirror window when one is
    /// bound; only without one does it fall back to the active window's sidebar.
    /// Prefer ``mirrorHostInNewWindow(host:)`` for the user-facing attach.
    func mirrorHost(host: RemoteTmuxHost) async throws {
        let dispatchFallback = AppDelegate.shared?.tabManager
        let sessions = try await transportRegistry.transport(for: host).discoverMirrorSessions(createIfEmpty: false)
        // Confirm the shared ControlMaster before the per-session attach burst, so
        // concurrent `ControlMaster=auto` attaches don't race to create it (#6732).
        try await ensureControlMasterReadyForBurst(host: host)
        // Post-await re-resolve: prefer a still-bound dedicated window (a mid-flight
        // close unbound it); focus changes must not retarget a live dispatch fallback.
        guard let appDelegate = AppDelegate.shared,
              let tabManager = RemoteTmuxController.mirrorTargetTabManager(
                  dedicatedWindowId: windowRegistry.windowId(forHostHash: host.connectionHash),
                  tabManagerForWindow: { appDelegate.tabManagerFor(windowId: $0) },
                  fallbackTabManager: { dispatchFallback?.window != nil ? dispatchFallback : appDelegate.tabManager }
              ) else {
            throw RemoteTmuxError.unreachable("app not ready")
        }
        mirrorSessions(sessions, host: host, into: tabManager)
    }

    /// The subset of `sessions` not yet mirrored for `host`: stable tmux ids beat
    /// mutable names so bulk discovery can't duplicate mid-rename.
    func unmirroredSessions(_ sessions: [RemoteTmuxSession], host: RemoteTmuxHost) -> [RemoteTmuxSession] {
        let mirrors = mirrorRegistry.allMirrors().filter { $0.host.connectionHash == host.connectionHash }
        return RemoteTmuxController.unmirroredSessions(
            sessions,
            mirroredSessionIds: Set(mirrors.compactMap { $0.connection.sessionId ?? $0.seededSessionId }),
            mirroredNames: Set(mirrors.map(\.sessionName))
        )
    }

    /// Mirrors each not-yet-mirrored session into `manager` (one failure must not
    /// abort the rest). Applies stable-id de-dup itself so every bulk entrypoint
    /// survives a rename race with raw input.
    func mirrorSessions(_ sessions: [RemoteTmuxSession], host: RemoteTmuxHost, into manager: TabManager) {
        for session in unmirroredSessions(sessions, host: host) {
            do {
                try mirrorSession(
                    host: host,
                    sessionName: session.name,
                    sessionId: RemoteTmuxController.tmuxSessionNumericId(session.id),
                    into: manager
                )
            } catch {
                #if DEBUG
                cmuxDebugLog("remote-tmux: mirror session \(session.name) on \(host.destination) failed: \(error)")
                #endif
            }
        }
    }

    /// Mirrors newly-discovered sessions into an existing dedicated window.
    ///
    /// Reuse paths skip the window-creation guard because mirroring is idempotent.
    /// Revalidation must stay after the last await so a closed window never
    /// receives invisible mirror workspaces.
    private func mirrorUnmirroredSessionsIntoDedicatedWindow(
        host: RemoteTmuxHost,
        windowId: UUID,
        sessions: [RemoteTmuxSession]
    ) async throws -> Bool {
        let unmirrored = unmirroredSessions(sessions, host: host)
        if !unmirrored.isEmpty {
            try await ensureControlMasterReadyForBurst(host: host)
            try Task.checkCancellation()
        }
        guard windowRegistry.windowId(forHostHash: host.connectionHash) == windowId,
              let manager = AppDelegate.shared?.tabManagerFor(windowId: windowId) else {
            return false
        }
        guard !unmirrored.isEmpty else { return true }
        mirrorSessions(unmirrored, host: host, into: manager)
        return true
    }

    /// Mirrors a single tmux session into a new workspace in `tabManager` (idempotent).
    @discardableResult
    func mirrorSession(
        host: RemoteTmuxHost,
        sessionName: String,
        sessionId: Int? = nil,
        into tabManager: TabManager
    ) throws -> Bool {
        let key = host.connectionKey(sessionName: sessionName)
        guard mirrorRegistry.mirror(forKey: key) == nil else { return false }
        // Attach (and start the ssh process) BEFORE creating the workspace, so a
        // failed connection doesn't leave an orphaned empty mirror workspace in
        // the sidebar.
        let connection = try connectionCoordinator.attach(host: host, sessionName: sessionName)
        let workspace = tabManager.addWorkspace(
            title: sessionName,
            select: false,
            autoWelcomeIfNeeded: false
        )
        workspace.isRemoteTmuxMirror = true
        mirrorRegistry.setMirror(
            RemoteTmuxSessionMirror(
                host: host,
                sessionName: sessionName,
                seededSessionId: sessionId,
                connection: connection,
                tabManager: tabManager,
                workspace: workspace
            ),
            forKey: key
        )
        return true
    }

    /// Creates a new tmux session on a dedicated remote window's host (and mirrors it
    /// into that window) when a new workspace is requested while a mirror tab is active.
    /// The single source of truth for the remote-vs-local decision, so every
    /// `performNewWorkspaceAction` entrypoint (double-tap, ⌘N, titlebar +, palette) is
    /// consistent.
    ///
    /// - Returns: `true` only when `windowId` is dedicated AND its active workspace is a
    ///   mirror (caller suppresses local creation); `false` otherwise — e.g. a dedicated
    ///   window whose active tab is a dragged-in local one, so the caller goes local.
    func handleRemoteWindowNewWorkspaceRequested(windowId: UUID) -> Bool {
        // The registry stores the full host (destination + port + identity), so
        // the new session reuses the exact connection details of the window's host.
        guard let host = windowRegistry.host(forWindowId: windowId) else { return false }
        guard let manager = AppDelegate.shared?.tabManagerFor(windowId: windowId) else { return true }
        // Gate on the ACTIVE workspace, not just the window: a dedicated window can
        // be polluted with a dragged-in local workspace (move targets don't exclude
        // dedicated windows), and a new workspace requested while that local tab is
        // active must stay local instead of spawning an unwanted tmux session.
        guard manager.selectedTab?.isRemoteTmuxMirror == true else { return false }
        Task { @MainActor in
            do {
                // Create a detached session and read back its (auto-assigned) name.
                let result = try await self.transportRegistry.transport(for: host).runTmux(
                    ["new-session", "-d", "-P", "-F", "#{session_name}"]
                )
                let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard result.succeeded, !name.isEmpty else { return }
                try self.mirrorSession(host: host, sessionName: name, into: manager)
            } catch {
                #if DEBUG
                cmuxDebugLog("remote-tmux: new-session on \(host.destination) failed: \(error)")
                #endif
            }
        }
        return true
    }
}
