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
    typealias SessionEndAction = RemoteTmuxSessionEndAction

    /// Diagnostic logger (not user-facing) for mirror lifecycle events such as a
    /// ControlMaster that couldn't be confirmed ready before the attach burst.
    nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app", category: "RemoteTmux")

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

    /// Owns the `tmux -CC` control-connection lifecycle (attach/reuse, ready-gated
    /// stream attach, per-host+session lookup). Constructed with this controller's
    /// shared (reference-type) registries, so it reads and re-keys the same live
    /// connection state and reaches the same transports.
    private let connectionCoordinator: RemoteTmuxConnectionCoordinator

    /// Discovers a host's tmux sessions and mirrors them into cmux windows/workspaces
    /// (dedicated-window attach, active-window mirror, per-session workspace, and the
    /// dedicated-window new-workspace routing). Constructed with this controller's
    /// shared (reference-type) registries and connection coordinator, so it reads and
    /// re-keys the same live window/mirror/transport/connection state.
    private let mirrorAttachCoordinator: RemoteTmuxMirrorAttachCoordinator

    init() {
        mirrorCommandRouter = RemoteTmuxMirrorCommandRouter(
            mirrorRegistry: mirrorRegistry,
            connectionRegistry: connectionRegistry
        )
        let connectionCoordinator = RemoteTmuxConnectionCoordinator(
            connectionRegistry: connectionRegistry,
            transportRegistry: transportRegistry
        )
        self.connectionCoordinator = connectionCoordinator
        mirrorAttachCoordinator = RemoteTmuxMirrorAttachCoordinator(
            windowRegistry: windowRegistry,
            mirrorRegistry: mirrorRegistry,
            transportRegistry: transportRegistry,
            connectionCoordinator: connectionCoordinator
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

    /// Forwards to ``RemoteTmuxConnectionCoordinator/attach(host:sessionName:createIfMissing:)``.
    @discardableResult
    func attach(
        host: RemoteTmuxHost,
        sessionName: String,
        createIfMissing: Bool = false
    ) throws -> RemoteTmuxControlConnection {
        try connectionCoordinator.attach(
            host: host,
            sessionName: sessionName,
            createIfMissing: createIfMissing
        )
    }

    /// Forwards to ``RemoteTmuxConnectionCoordinator/attachControlStreamWhenReady(host:sessionName:createIfMissing:)``.
    func attachControlStreamWhenReady(
        host: RemoteTmuxHost,
        sessionName: String,
        createIfMissing: Bool = false
    ) async throws -> [String]? {
        try await connectionCoordinator.attachControlStreamWhenReady(
            host: host,
            sessionName: sessionName,
            createIfMissing: createIfMissing
        )
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

    /// Forwards to ``RemoteTmuxMirrorAttachCoordinator/mirrorHostInNewWindow(host:activateWindow:)``.
    @discardableResult
    func mirrorHostInNewWindow(
        host: RemoteTmuxHost,
        activateWindow: Bool = true
    ) async throws -> RemoteTmuxAttachOutcome {
        try await mirrorAttachCoordinator.mirrorHostInNewWindow(host: host, activateWindow: activateWindow)
    }

    /// Forwards to ``RemoteTmuxMirrorAttachCoordinator/mirrorHost(host:)``.
    func mirrorHost(host: RemoteTmuxHost) async throws {
        try await mirrorAttachCoordinator.mirrorHost(host: host)
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

    /// Forwards to ``RemoteTmuxMirrorCommandRouter/cachedMirrorTabActivity(workspaceId:panelId:)``.
    func cachedMirrorTabActivity(workspaceId: UUID, panelId: UUID) -> MirrorTabActivity? {
        mirrorCommandRouter.cachedMirrorTabActivity(workspaceId: workspaceId, panelId: panelId)
    }

    /// Forwards to ``RemoteTmuxMirrorCommandRouter/queryMirrorTabActivity(workspaceId:panelId:completion:)``.
    func queryMirrorTabActivity(
        workspaceId: UUID, panelId: UUID, completion: @escaping (MirrorTabActivity) -> Void
    ) {
        mirrorCommandRouter.queryMirrorTabActivity(workspaceId: workspaceId, panelId: panelId, completion: completion)
    }

    /// Forwards to ``RemoteTmuxMirrorAttachCoordinator/handleRemoteWindowNewWorkspaceRequested(windowId:)``.
    func handleRemoteWindowNewWorkspaceRequested(windowId: UUID) -> Bool {
        mirrorAttachCoordinator.handleRemoteWindowNewWorkspaceRequested(windowId: windowId)
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

    /// Forwards to ``RemoteTmuxConnectionCoordinator/connection(host:sessionName:)``.
    func connection(host: RemoteTmuxHost, sessionName: String) -> RemoteTmuxControlConnection? {
        connectionCoordinator.connection(host: host, sessionName: sessionName)
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
