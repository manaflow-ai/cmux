import Foundation
import CmuxSettings

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
    typealias SessionEndAction = RemoteTmuxSessionEndAction

    /// Per-endpoint SSH transports (keyed by ``RemoteTmuxHost/connectionHash``),
    /// owned by ``RemoteTmuxController`` and delegated to for discovery + master teardown.
    private let transportRegistry = RemoteTmuxTransportRegistry()

    /// Live `tmux -CC` control connections keyed by `connectionHash\u{1}session`
    /// (see ``RemoteTmuxHost/connectionKey(sessionName:)``), so repeated attach requests for
    /// the same endpoint+session reuse the existing connection, owned by
    /// ``RemoteTmuxController`` and delegated to.
    private let connectionRegistry = RemoteTmuxControlConnectionRegistry()

    /// Routes mirror user-actions (new tab, rename, reorder, split, paste, close)
    /// to the remote control connection and answers the mirror-membership
    /// lookups those routes depend on. Constructed with this controller's shared
    /// (reference-type) registries, so it reads and re-keys the same live state.
    private let mirrorCommandRouter: RemoteTmuxMirrorCommandRouter

    init() {
        mirrorCommandRouter = RemoteTmuxMirrorCommandRouter(
            mirrorRegistry: mirrorRegistry,
            connectionRegistry: connectionRegistry
        )
    }

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

    // MARK: - Control connections (tmux -CC mirroring)

    /// Attaches a `tmux -CC` control connection to `sessionName` on `host`,
    /// reusing an existing live connection for the same host+session.
    @discardableResult
    func attach(
        host: RemoteTmuxHost,
        sessionName: String,
        createIfMissing: Bool = false
    ) throws -> RemoteTmuxControlConnection {
        let key = host.connectionKey(sessionName: sessionName)
        if let existing = connectionRegistry.connection(forKey: key) {
            if !existing.exited { return existing }
            // Replace a dead connection — fully tear down the old one first so
            // its ssh process, stdin fd, stream continuation and ingest task
            // don't leak.
            existing.stop()
            connectionRegistry.removeConnection(forKey: key)
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
        connectionRegistry.setConnection(connection, forKey: key)
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
        if let sshArgv = try await transport(for: host).preflightControlAttach(
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
        let key = host.connectionKey(sessionName: sessionName)
        guard connectionRegistry.connection(forKey: key) === connection else { return }
        connectionRegistry.removeConnection(forKey: key)
        connection.stop()
    }

    // MARK: - Sidebar mirroring (P3, initial increment)

    /// Active session→workspace mirrors keyed `connectionHash\u{1}session`
    /// (see ``RemoteTmuxHost/connectionKey(sessionName:)``), owned by
    /// ``RemoteTmuxController`` and delegated to.
    private let mirrorRegistry = RemoteTmuxSessionMirrorRegistry()

    /// Dedicated-window bindings (host↔window) and the in-flight-attach guard for
    /// the "one cmux window per remote endpoint" mirror mode (Option 1), owned by
    /// ``RemoteTmuxController`` and delegated to.
    private let windowRegistry = RemoteTmuxWindowRegistry()

    /// Returns `true` if `windowId` is a dedicated remote-tmux mirror window.
    /// Used by the session-snapshot path to exclude these windows: a mirror window
    /// needs a live SSH connection and can't be restored from a generic snapshot.
    func isDedicatedRemoteWindow(_ windowId: UUID) -> Bool {
        windowRegistry.isDedicatedWindow(windowId)
    }

#if DEBUG
    func bindDedicatedWindowForTesting(host: RemoteTmuxHost, windowId: UUID) {
        windowRegistry.bind(host: host, windowId: windowId)
    }

    func unbindDedicatedWindowForTesting(windowId: UUID) {
        windowRegistry.unbind(windowId: windowId)
    }
#endif

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
        // (BatchMode can't prompt); classify that and hand back the interactive
        // `ssh` argv so the `cmux ssh-tmux` CLI authenticates in the user's terminal
        // and retries — the retry then rides the now-open master. `transport.run()`
        // creates the control-socket dir, so the returned auth `ssh` can open the
        // master. No window has been created yet — nothing to tear down here. Both
        // discovery calls (including the create-then-relist for an empty server) are
        // inside the catch so an auth failure on either is classified uniformly.
        let sessions: [RemoteTmuxSession]
        do {
            var discovered = try await listSessions(host: host)
            if discovered.isEmpty {
                // A reachable server with zero sessions: create one so the window
                // is useful. (An unreachable host throws from listSessions.)
                _ = try? await transport(for: host).runTmux(["new-session", "-d"])
                discovered = try await listSessions(host: host)
            }
            sessions = discovered
        } catch let error as RemoteTmuxError {
            if case .commandFailed(_, let stderr) = error,
               RemoteTmuxSSHTransport.indicatesAuthRequired(stderr) {
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
            return .mirrored(windowId: existing)
        }

        // Bail before creating a window the caller has abandoned. The socket handler
        // runs this under a v2VmCall timeout that cancels the task on expiry, but the
        // SSH discovery awaits above are not cancellation-aware — a slow-but-successful
        // probe could otherwise land here after the caller already received a timeout
        // and open an orphaned dedicated window (with live SSH/tmux behind it).
        try Task.checkCancellation()

        let windowId = appDelegate.createMainWindow(shouldActivate: activateWindow)
        guard let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            throw RemoteTmuxError.unreachable("could not create window")
        }
        windowRegistry.bind(host: host, windowId: windowId)

        let bootstrapWorkspaceId = manager.tabs.first?.id
        for session in sessions {
            do {
                try mirrorSession(host: host, sessionName: session.name, into: manager)
            } catch {
                #if DEBUG
                cmuxDebugLog("remote-tmux: mirror session \(session.name) on \(host.destination) failed: \(error)")
                #endif
            }
        }
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
    /// workspace in the active window's sidebar (Option 2 — used by the
    /// `remote.tmux.mirror` socket command). Prefer
    /// ``mirrorHostInNewWindow(host:)`` for the user-facing attach.
    func mirrorHost(host: RemoteTmuxHost) async throws {
        guard let tabManager = AppDelegate.shared?.tabManager else {
            throw RemoteTmuxError.unreachable("app not ready")
        }
        let sessions = try await listSessions(host: host)
        for session in sessions {
            // One session failing to attach must not abort mirroring the rest.
            do {
                try mirrorSession(host: host, sessionName: session.name, into: tabManager)
            } catch {
                #if DEBUG
                cmuxDebugLog("remote-tmux: mirror session \(session.name) on \(host.destination) failed: \(error)")
                #endif
            }
        }
    }

    /// Mirrors a single tmux session into a new workspace in `tabManager` (idempotent).
    @discardableResult
    func mirrorSession(
        host: RemoteTmuxHost,
        sessionName: String,
        into tabManager: TabManager
    ) throws -> Bool {
        let key = host.connectionKey(sessionName: sessionName)
        guard mirrorRegistry.mirror(forKey: key) == nil else { return false }
        // Attach (and start the ssh process) BEFORE creating the workspace, so a
        // failed connection doesn't leave an orphaned empty mirror workspace in
        // the sidebar.
        let connection = try attach(host: host, sessionName: sessionName)
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
                connection: connection,
                workspace: workspace
            ),
            forKey: key
        )
        return true
    }

    // MARK: - Create / destroy propagation (P5)
    //
    // Relocated to ``RemoteTmuxMirrorCommandRouter`` (mirror user-action →
    // remote control-connection routing + mirror-membership lookups). These
    // forwarders preserve the controller's public entrypoints for the socket /
    // CLI / sidebar / surface callers that reach the cluster through
    // `AppDelegate.shared?.remoteTmuxController` and the workspace host
    // environment.

    /// Forwards to ``RemoteTmuxMirrorCommandRouter/handleMirrorNewTabRequested(workspaceId:)``.
    func handleMirrorNewTabRequested(workspaceId: UUID) -> Bool {
        mirrorCommandRouter.handleMirrorNewTabRequested(workspaceId: workspaceId)
    }

    /// Forwards to ``RemoteTmuxMirrorCommandRouter/handleMirrorWorkspaceRenamed(workspaceId:title:)``.
    func handleMirrorWorkspaceRenamed(workspaceId: UUID, title: String?) {
        mirrorCommandRouter.handleMirrorWorkspaceRenamed(workspaceId: workspaceId, title: title)
    }

    /// Forwards to ``RemoteTmuxMirrorCommandRouter/handleMirrorSessionNameChanged(mirror:oldName:newName:)``.
    func handleMirrorSessionNameChanged(
        mirror: RemoteTmuxSessionMirror,
        oldName: String,
        newName: String
    ) {
        mirrorCommandRouter.handleMirrorSessionNameChanged(mirror: mirror, oldName: oldName, newName: newName)
    }

    /// Forwards to ``RemoteTmuxMirrorCommandRouter/handleMirrorWindowsReordered(workspaceId:orderedPanelIds:)``.
    func handleMirrorWindowsReordered(workspaceId: UUID, orderedPanelIds: [UUID]) {
        mirrorCommandRouter.handleMirrorWindowsReordered(workspaceId: workspaceId, orderedPanelIds: orderedPanelIds)
    }

    /// Forwards to ``RemoteTmuxMirrorCommandRouter/handleMirrorSplitRequested(surfaceId:vertical:)``.
    func handleMirrorSplitRequested(surfaceId: UUID, vertical: Bool) -> Bool {
        mirrorCommandRouter.handleMirrorSplitRequested(surfaceId: surfaceId, vertical: vertical)
    }

    /// Forwards to ``RemoteTmuxMirrorCommandRouter/isMirrorPaneSurface(_:)``.
    func isMirrorPaneSurface(_ surfaceId: UUID) -> Bool {
        mirrorCommandRouter.isMirrorPaneSurface(surfaceId)
    }

    /// Forwards to ``RemoteTmuxMirrorCommandRouter/pasteIntoMirror(surfaceId:text:)``.
    func pasteIntoMirror(surfaceId: UUID, text: String) -> Bool {
        mirrorCommandRouter.pasteIntoMirror(surfaceId: surfaceId, text: text)
    }

    /// Forwards to ``RemoteTmuxMirrorCommandRouter/remoteUploadTarget(forSurfaceId:)``.
    func remoteUploadTarget(forSurfaceId surfaceId: UUID) -> TerminalRemoteUploadTarget? {
        mirrorCommandRouter.remoteUploadTarget(forSurfaceId: surfaceId)
    }

    /// Forwards to ``RemoteTmuxMirrorCommandRouter/handleMirrorTabSplitRequested(workspaceId:panelId:vertical:)``.
    func handleMirrorTabSplitRequested(workspaceId: UUID, panelId: UUID, vertical: Bool) -> Bool {
        mirrorCommandRouter.handleMirrorTabSplitRequested(workspaceId: workspaceId, panelId: panelId, vertical: vertical)
    }

    /// Forwards to ``RemoteTmuxMirrorCommandRouter/handleMirrorWindowRenamed(workspaceId:panelId:title:)``.
    func handleMirrorWindowRenamed(workspaceId: UUID, panelId: UUID, title: String?) {
        mirrorCommandRouter.handleMirrorWindowRenamed(workspaceId: workspaceId, panelId: panelId, title: title)
    }

    /// Forwards to ``RemoteTmuxMirrorCommandRouter/isMirrorWindowTab(workspaceId:panelId:)``.
    func isMirrorWindowTab(workspaceId: UUID, panelId: UUID) -> Bool {
        mirrorCommandRouter.isMirrorWindowTab(workspaceId: workspaceId, panelId: panelId)
    }

    /// Forwards to ``RemoteTmuxMirrorCommandRouter/handleMirrorTabCloseRequested(workspaceId:panelId:)``.
    func handleMirrorTabCloseRequested(workspaceId: UUID, panelId: UUID) -> Bool {
        mirrorCommandRouter.handleMirrorTabCloseRequested(workspaceId: workspaceId, panelId: panelId)
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
        return RemoteTmuxMirrorTabActivity.from(
            states: states, paneOrder: order,
            activePaneId: connection.activePaneByWindow[target.windowId]
        )
    }

    /// The cached activity answer for a mirrored window-tab, or `nil` when
    /// `panelId` isn't a live mirrored window-tab. Used where a round trip
    /// isn't warranted (the always-warn dialog path).
    func cachedMirrorTabActivity(workspaceId: UUID, panelId: UUID) -> MirrorTabActivity? {
        guard let target = mirrorCommandRouter.mirrorWindowTarget(workspaceId: workspaceId, panelId: panelId) else { return nil }
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
        guard let target = mirrorCommandRouter.mirrorWindowTarget(workspaceId: workspaceId, panelId: panelId) else {
            completion(MirrorTabActivity(hasActiveCommand: false, activeCommandName: nil))
            return
        }
        // Strong captures: the controller is app-lifetime and the completion
        // fires exactly once (flushed on stream resets), so nothing can leak.
        target.mirror.connection.queryWindowActivity(windowId: target.windowId) { states in
            if let states {
                let connection = target.mirror.connection
                completion(RemoteTmuxMirrorTabActivity.from(
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
                let result = try await self.transport(for: host).runTmux(
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

    /// The remote tmux session ended FOR GOOD (its last window was killed, it was
    /// killed out-of-band, or a reconnect found it gone) — remove the mirror +
    /// connection and either close the now-dead workspace or, when the host's
    /// dedicated window just lost its last session, close that whole window. Never
    /// issues a kill (the session is already gone). A transient transport loss does
    /// NOT reach here — the connection reconnects instead.
    func handleSessionEndedRemotely(
        host: RemoteTmuxHost,
        sessionName: String,
        workspaceId: UUID
    ) {
        let key = host.connectionKey(sessionName: sessionName)
        if let mirror = mirrorRegistry.removeMirror(forKey: key) {
            mirror.detachObserver()
        }
        connectionRegistry.removeConnection(forKey: key)?.stop()
        let hostHasOtherMirrors = mirrorRegistry.hasMirror(forHostHash: host.connectionHash)
        // The dedicated window for this host, captured before the bindings are torn
        // down. `nil` once other sessions remain — losing one of several sessions
        // closes only its workspace, never the shared window.
        let dedicatedWindowId = hostHasOtherMirrors ? nil : windowRegistry.windowId(forHostHash: host.connectionHash)
        // Decide the UI action BEFORE tearing down persistence/bindings, so the
        // persistence decision can depend on whether the dedicated window is
        // actually closing.
        //
        // The mirror was already removed above, so any close path's kill hook finds
        // no entry and won't re-issue a kill.
        //
        // Only close the whole dedicated window when it still exists and every
        // workspace in it belongs to THIS host (the dead workspace, or another live
        // mirror for the same host). The user may have moved a local workspace — or
        // another host's mirror — into it (dedicated windows aren't excluded from
        // move targets), and a disconnect must never discard unrelated work.
        // Resolving the manager here also makes the window-count math robust to the
        // window already being gone (a concurrent user close): the count then
        // excludes nothing.
        let dedicatedManager = dedicatedWindowId.flatMap { AppDelegate.shared?.tabManagerFor(windowId: $0) }
        let dedicatedWindowIsOpen = dedicatedManager != nil
        // Workspaces owned by the ending host: the just-ended one plus any other
        // still-live mirrors for the same host (none once hostHasOtherMirrors is
        // false, but computed generally).
        let endingHostWorkspaceIds: Set<UUID> = Set(
            mirrorRegistry.allMirrors()
                .filter { $0.host.connectionHash == host.connectionHash }
                .compactMap { $0.mirroredWorkspaceId }
        ).union([workspaceId])
        let ownedByEndingHost = dedicatedManager?.tabs.allSatisfy { endingHostWorkspaceIds.contains($0.id) } ?? false
        let totalMainWindowCount = AppDelegate.shared?.registeredMainWindows.count ?? 0
        let otherMainWindowCount = max(0, totalMainWindowCount - (dedicatedWindowIsOpen ? 1 : 0))
        let action = RemoteTmuxSessionEndAction.resolve(
            dedicatedWindowId: dedicatedWindowIsOpen ? dedicatedWindowId : nil,
            dedicatedWindowOwnedByEndingHost: ownedByEndingHost,
            otherMainWindowCount: otherMainWindowCount
        )
        if !hostHasOtherMirrors {
            // The host's last session is gone, so close its shared SSH ControlMaster
            // now — but only if no other control connection (e.g. a
            // remote.tmux.attach for the same endpoint) is still multiplexing
            // over it. We must do it here rather than rely on the window's onClose
            // hook: clearing the binding just below makes handleRemoteWindowClosed a
            // no-op, and the dedicated window may be closed programmatically (the
            // `.closeDedicatedWindow` path), so the hook can't be the one to tear the
            // master down.
            let hostHasOtherConnections = connectionRegistry.hasConnection(forHostHash: host.connectionHash)
            if !hostHasOtherConnections {
                transportRegistry.remove(connectionHash: host.connectionHash)
                RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
            }
            // Drop the dedicated-window binding (the window is either closing, or
            // converting to a plain local window — either way it is no longer a
            // remote mirror). Done before the switch so the window's onClose hook's
            // handleRemoteWindowClosed finds the binding gone and is a no-op.
            windowRegistry.unbind(hostHash: host.connectionHash)
        }
        #if DEBUG
        cmuxDebugLog(
            "remote-tmux: session ended host=\(host.destination) session=\(sessionName) " +
            "hostHasOtherMirrors=\(hostHasOtherMirrors) dedicatedWindowOpen=\(dedicatedWindowIsOpen) " +
            "ownedByEndingHost=\(ownedByEndingHost) otherWindows=\(otherMainWindowCount) action=\(action)"
        )
        #endif
        switch action {
        case let .closeDedicatedWindow(windowId):
            // Tear down the whole dedicated window (true detach UX). Uses
            // `window.close()` (not `performClose`) so the disconnect never raises
            // the "close window?" confirmation, and suppresses closed-window history
            // (a dead-remote window isn't meaningfully restorable). The window's
            // onClose hook detaches any remaining state; the mirror/connection for
            // this session were already removed above.
            AppDelegate.shared?.discardMainWindowWithoutClosedHistory(windowId: windowId)
        case .closeWorkspace:
            // Close just the dead workspace. `closeWorkspace` refuses to remove a
            // window's last workspace (it would leave a windowless state), so if the
            // dead mirror is the only workspace in its window, add a fresh local
            // workspace first — that leaves a usable window instead of stranding a
            // frozen, connection-less remote tab. `inheritWorkingDirectory: false`
            // avoids inheriting the mirror's remote path; `select: false` keeps the
            // disconnect from stealing focus (closeWorkspace reselects after the
            // dead one is removed).
            if let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
               let workspace = manager.tabs.first(where: { $0.id == workspaceId }) {
                if manager.tabs.count == 1 {
                    _ = manager.addWorkspace(inheritWorkingDirectory: false, select: false)
                }
                manager.closeWorkspace(workspace)
            }
        }
    }

    /// Detaches any session mirrors whose workspace is in a closing window
    /// (covers the `remote.tmux.mirror` socket path that mirrors into a
    /// non-dedicated window, whose generic close doesn't run handleWorkspaceClosed).
    /// Window close = detach + preserve remote (no kill); pane surfaces are torn
    /// down via `detachObserver`.
    func handleWindowWorkspacesClosed(workspaceIds: [UUID]) {
        let ids = Set(workspaceIds)
        var affectedHosts: [String: RemoteTmuxHost] = [:]
        for (key, mirror) in mirrorRegistry.allEntries() {
            guard let workspaceId = mirror.mirroredWorkspaceId, ids.contains(workspaceId) else { continue }
            affectedHosts[mirror.host.connectionHash] = mirror.host
            mirror.detachObserver()
            mirrorRegistry.removeMirror(forKey: key)
            connectionRegistry.removeConnection(forKey: key)?.stop()
        }
        // For any host left with no live mirror or connection, close its shared SSH
        // ControlMaster now — the dedicated-window/last-session paths already do this,
        // and a non-dedicated `remote.tmux.mirror` window must too or the master
        // lingers for the full ControlPersist window.
        for (hash, host) in affectedHosts {
            let stillUsed = mirrorRegistry.hasMirror(forHostHash: hash)
                || connectionRegistry.hasConnection(forHostHash: hash)
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
            guard windowRegistry.consumeKillSessionsOnClose(windowId: windowId),
                  let host = windowRegistry.host(forWindowId: windowId) else { continue }
            let closingWorkspaceIds = Set(AppDelegate.shared?.tabManagerFor(windowId: windowId)?.tabs.map(\.id) ?? [])
            let transport = transport(for: host)
            let mirrorsInWindow = mirrorRegistry.allEntries().filter { _, mirror in
                mirror.host.connectionHash == host.connectionHash
                    && mirror.mirroredWorkspaceId.map(closingWorkspaceIds.contains) == true
            }
            for (key, mirror) in mirrorsInWindow {
                mirrorRegistry.removeMirror(forKey: key)
                mirror.detachObserver()
                detach(host: host, sessionName: mirror.sessionName)  // removes the connection too
                jobs.append((transport, mirror.connection.sessionId.map { "$\($0)" } ?? mirror.sessionName))
            }
            let stillUsed = mirrorRegistry.hasMirror(forHostHash: host.connectionHash) || connectionRegistry.hasConnection(forHostHash: host.connectionHash)
            if !stillUsed {
                windowRegistry.unbind(hostHash: host.connectionHash)
                transportRegistry.remove(connectionHash: host.connectionHash)
            }
        }
        await RemoteTmuxSSHTransport.killSessions(jobs, timeout: timeout)
    }

    /// Dedicated window close detaches only that window's mirrors; same-host mirrors
    /// in other windows keep their control streams.
    func handleRemoteWindowClosed(windowId: UUID) {
        guard let host = windowRegistry.host(forWindowId: windowId) else { return }
        let closingWorkspaceIds = Set(AppDelegate.shared?.tabManagerFor(windowId: windowId)?.tabs.map(\.id) ?? [])
        windowRegistry.unbind(windowId: windowId)
        let mirrorsInWindow = mirrorRegistry.allEntries().filter { _, mirror in
            mirror.host.connectionHash == host.connectionHash
                && mirror.mirroredWorkspaceId.map(closingWorkspaceIds.contains) == true
        }
        for (key, mirror) in mirrorsInWindow {
            mirror.detachObserver()
            mirrorRegistry.removeMirror(forKey: key)
            connectionRegistry.removeConnection(forKey: key)?.stop()
        }
        let stillUsed = mirrorRegistry.hasMirror(forHostHash: host.connectionHash) || connectionRegistry.hasConnection(forHostHash: host.connectionHash)
        if !stillUsed {
            transportRegistry.remove(connectionHash: host.connectionHash)
            RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
        }
    }

    /// Handles user-initiated close of a mirrored session workspace: detaches the
    /// control connection and kills the session on the remote. (The app-quit path
    /// uses ``killMarkedSessionsBeforeTerminate(timeout:)`` instead, which awaits the
    /// kill so it lands before cmux exits.)
    func handleWorkspaceClosed(workspaceId: UUID) {
        guard let entry = mirrorRegistry.allEntries().first(where: { $0.mirror.mirroredWorkspaceId == workspaceId })
        else { return }
        let mirror = entry.mirror
        let host = mirror.host
        let sessionName = mirror.sessionName
        mirrorRegistry.removeMirror(forKey: entry.key)
        mirror.detachObserver()
        detach(host: host, sessionName: sessionName)
        // Last mirrored session for this host: drop the dedicated-window binding (so
        // the window's onClose handleRemoteWindowClosed becomes a no-op) and tear down
        // the shared SSH ControlMaster, matching the remote-end and window-close paths.
        let isLastSession = !mirrorRegistry.hasMirror(forHostHash: host.connectionHash)
        if isLastSession {
            windowRegistry.unbind(hostHash: host.connectionHash)
        }
        // Kill by the stable session id when known, so a prior rename-session
        // can't leave us targeting a stale name.
        let killTarget = mirror.connection.sessionId.map { "$\($0)" } ?? sessionName
        let transport = transport(for: host)
        if isLastSession {
            // Drop the transport so a later re-attach builds a fresh one instead of
            // reusing this soon-to-be-dead master.
            transportRegistry.remove(connectionHash: host.connectionHash)
        }
        Task {
            _ = try? await transport.runTmux(["kill-session", "-t", killTarget])
            // Close the master only after kill-session has used it; `ssh -O exit`
            // first would tear the connection down before the session dies.
            if isLastSession {
                // …and only if no reattach reclaimed this endpoint during the kill
                // round-trip (a concurrent `cmux ssh-tmux` rebuilds on the same
                // ControlPath); this Task is @MainActor so check + exit is atomic.
                let reclaimed = transportRegistry.contains(connectionHash: host.connectionHash)
                    || mirrorRegistry.hasMirror(forHostHash: host.connectionHash)
                    || connectionRegistry.hasConnection(forHostHash: host.connectionHash)
                if !reclaimed {
                    RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
                }
            }
        }
    }

    /// Returns the control connection for a host+session, if attached.
    func connection(host: RemoteTmuxHost, sessionName: String) -> RemoteTmuxControlConnection? {
        connectionRegistry.connection(forKey: host.connectionKey(sessionName: sessionName))
    }

    /// Detaches and forgets a control connection (leaves the remote session alive).
    func detach(host: RemoteTmuxHost, sessionName: String) {
        let key = host.connectionKey(sessionName: sessionName)
        connectionRegistry.removeConnection(forKey: key)?.stop()
    }

    /// Detaches every control connection on app quit and closes the shared SSH
    /// ControlMasters, so quitting cmux closes the ssh connections it opened (the
    /// CLI's `ssh -f` left them persistent). Does NOT kill any remote tmux
    /// server/session — only the local control clients and masters.
    func detachAll() {
        let connections = connectionRegistry.allConnections()
        connectionRegistry.removeAll()
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

}
