import Foundation
import CmuxSettings

/// Coordinates cmux's mirroring of remote tmux servers.
///
/// Owns one ``RemoteTmuxSSHTransport`` per host (keyed by SSH destination) and
/// is the entry point the socket/CLI layer and (later) the UI call into. It is
/// `@MainActor` because it will own sidebar/workspace state as the feature
/// grows; today it performs discovery by delegating to the per-host transport
/// actor.
///
/// Constructed once and held by `AppDelegate` (no global singleton), so it can
/// be reached from the v2 socket dispatcher via `AppDelegate.shared`.
@MainActor
final class RemoteTmuxController {
    private var transports: [String: RemoteTmuxSSHTransport] = [:]

    /// Live `tmux -CC` control connections keyed by `destination\u{1}session`,
    /// so repeated attach requests reuse the existing connection.
    private var connectionsByHostSession: [String: RemoteTmuxControlConnection] = [:]

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
        if let existing = transports[host.destination] {
            return existing
        }
        let transport = RemoteTmuxSSHTransport(host: host)
        transports[host.destination] = transport
        return transport
    }

    /// Discovers the tmux sessions on a host.
    func listSessions(host: RemoteTmuxHost) async throws -> [RemoteTmuxSession] {
        try await transport(for: host).listSessions()
    }

    /// Tears down a host's shared SSH master (used when removing a host).
    func disconnect(host: RemoteTmuxHost) async {
        let transport = transports.removeValue(forKey: host.destination)
        await transport?.shutdownMaster()
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
        let key = Self.connectionKey(destination: host.destination, sessionName: sessionName)
        if let existing = connectionsByHostSession[key] {
            if !existing.exited { return existing }
            // Replace a dead connection — fully tear down the old one first so
            // its ssh process, stdin fd, stream continuation and ingest task
            // don't leak.
            existing.stop()
            connectionsByHostSession.removeValue(forKey: key)
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
        connectionsByHostSession[key] = connection
        return connection
    }

    // MARK: - Sidebar mirroring (P3, initial increment)

    /// Display panels mirroring a remote pane, keyed `dest\u{1}session\u{1}pane`.
    private var displayPanels: [String: TerminalPanel] = [:]

    /// Observer tokens for the single-pane display path, keyed by connection key.
    private var displayObserverTokens: [String: RemoteTmuxControlConnection.ObserverToken] = [:]

    /// Attaches a session and mirrors its active window's first pane as a live
    /// display tab in a workspace. The tab renders the remote pane's output and
    /// forwards keystrokes back to it.
    ///
    /// This is the "attach a single remote pane into a cmux tab" path; full
    /// session→workspace / window→tab mirroring is ``mirrorSession(host:sessionName:)``.
    ///
    /// - Parameters:
    ///   - host: the remote SSH destination.
    ///   - sessionName: the tmux session to attach to.
    ///   - focus: when `true`, selects and focuses the created tab (user-initiated
    ///     attach). Socket/background callers pass `false` so they never steal the
    ///     user's keyboard focus, per the socket focus policy.
    func openActivePane(host: RemoteTmuxHost, sessionName: String, focus: Bool = false) throws {
        let connection = try attach(host: host, sessionName: sessionName)
        let key = Self.connectionKey(destination: host.destination, sessionName: sessionName)
        // Capture the target workspace at command time. Topology often arrives
        // asynchronously (after the first %layout-change), so resolving the
        // workspace inside the callback would build the tab in whichever
        // workspace happens to be selected when topology lands.
        guard let targetWorkspaceId = AppDelegate.shared?.tabManager?.selectedWorkspace?.id else {
            throw RemoteTmuxError.unreachable("no active workspace")
        }
        // Register an observer (don't overwrite a single closure): the connection
        // is shared with any concurrent mirror of the same session.
        if displayObserverTokens[key] == nil {
            displayObserverTokens[key] = connection.addObserver(
                onPaneOutput: { [weak self] paneId, data in
                    self?.displayPanels["\(key)\u{1}\(paneId)"]?.surface.processRemoteOutput(data)
                },
                onTopologyChanged: { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.buildDisplayIfNeeded(connection: connection, key: key, workspaceId: targetWorkspaceId, focus: focus)
                }
            )
        }
        buildDisplayIfNeeded(connection: connection, key: key, workspaceId: targetWorkspaceId, focus: focus)
    }

    private func buildDisplayIfNeeded(
        connection: RemoteTmuxControlConnection,
        key: String,
        workspaceId: UUID,
        focus: Bool
    ) {
        guard let firstWindowId = connection.windowOrder.first,
              let window = connection.windowsByID[firstWindowId],
              let paneId = window.paneIDsInOrder.first else { return }
        let panelKey = "\(key)\u{1}\(paneId)"
        guard displayPanels[panelKey] == nil else { return }
        guard let workspace = AppDelegate.shared?.tabManager?.tabs.first(where: { $0.id == workspaceId })
        else { return }
        guard let panel = workspace.addRemoteTmuxDisplayPane(
            remotePaneId: paneId,
            focus: focus,
            onInput: { [weak connection] data in
                Task { @MainActor in connection?.sendKeys(paneId: paneId, data: data) }
            }
        ) else { return }
        displayPanels[panelKey] = panel
        // Prime the pane with its current contents so it isn't blank on open.
        connection.capturePane(paneId: paneId)
    }

    /// Active session→workspace mirrors keyed `dest\u{1}session`.
    private var sessionMirrors: [String: RemoteTmuxSessionMirror] = [:]

    /// SSH destination → the dedicated cmux window mirroring that host (Option 1).
    private var windowIdByHost: [String: UUID] = [:]
    /// Reverse map: cmux window id → the host it mirrors (for window-close detach).
    private var hostByWindowId: [UUID: String] = [:]
    /// Destinations with an in-flight ``mirrorHostInNewWindow(host:activateWindow:)``,
    /// so a re-entrant call across the `await` gap can't open a second window.
    private var pendingHostAttaches: Set<String> = []

    /// Returns `true` if `windowId` is a dedicated remote-tmux mirror window.
    /// Used by the session-snapshot path to exclude these windows (they are
    /// rebuilt by ``restoreMirroredHostsOnLaunch()``, not the generic restore).
    func isDedicatedRemoteWindow(_ windowId: UUID) -> Bool {
        hostByWindowId[windowId] != nil
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
    ///     activated/focused. Restore-on-launch passes `false` so a relaunch
    ///     doesn't steal focus.
    /// - Returns: the cmux window id hosting the mirror.
    /// - Throws: ``RemoteTmuxError`` if the host is unreachable or has no tmux
    ///   sessions (no empty dedicated window is created in that case).
    @discardableResult
    func mirrorHostInNewWindow(host: RemoteTmuxHost, activateWindow: Bool = true) async throws -> UUID {
        guard let appDelegate = AppDelegate.shared else {
            throw RemoteTmuxError.unreachable("app not ready")
        }
        // Reuse the dedicated window if this host is already mirrored.
        if let existing = windowIdByHost[host.destination],
           let window = appDelegate.windowForMainWindowId(existing) {
            if activateWindow { window.makeKeyAndOrderFront(nil) }
            return existing
        }
        // Guard the await gap: a second concurrent attach for the same host must
        // not open a second window.
        guard !pendingHostAttaches.contains(host.destination) else {
            throw RemoteTmuxError.unreachable("already attaching \(host.destination)")
        }
        pendingHostAttaches.insert(host.destination)
        defer { pendingHostAttaches.remove(host.destination) }

        var sessions = try await listSessions(host: host)
        if sessions.isEmpty {
            // A reachable server with zero sessions: create one so the window is
            // useful. (An unreachable host throws from listSessions above.)
            _ = try? await transport(for: host).runTmux(["new-session", "-d"])
            sessions = try await listSessions(host: host)
        }
        // Never open an empty dedicated window.
        guard !sessions.isEmpty else {
            throw RemoteTmuxError.unreachable("no tmux sessions on \(host.destination)")
        }
        // Re-check reuse: a concurrent caller may have finished while we awaited.
        if let existing = windowIdByHost[host.destination],
           let window = appDelegate.windowForMainWindowId(existing) {
            if activateWindow { window.makeKeyAndOrderFront(nil) }
            return existing
        }

        let windowId = appDelegate.createMainWindow(shouldActivate: activateWindow)
        guard let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            throw RemoteTmuxError.unreachable("could not create window")
        }
        windowIdByHost[host.destination] = windowId
        hostByWindowId[windowId] = host.destination

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
        // Remove the window's bootstrap (local welcome) workspace once at least
        // one remote workspace exists, so the window is a clean 1:1 mirror.
        if let bootstrapWorkspaceId,
           manager.tabs.count > 1,
           let bootstrap = manager.tabs.first(where: { $0.id == bootstrapWorkspaceId }),
           !bootstrap.isRemoteTmuxMirror {
            manager.closeWorkspace(bootstrap, recordHistory: false)
        }
        if sessionMirrors.values.contains(where: { $0.host.destination == host.destination }) {
            addPersistedMirroredHost(host)
        }
        return windowId
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
        // Remember the host for relaunch only once it actually has a live mirror,
        // so an unreachable / sessionless host isn't persisted forever with no
        // way to forget it through the UI.
        if sessionMirrors.values.contains(where: { $0.host.destination == host.destination }) {
            addPersistedMirroredHost(host)
        }
    }

    /// Mirrors a single tmux session into a new workspace in `tabManager` (idempotent).
    @discardableResult
    func mirrorSession(
        host: RemoteTmuxHost,
        sessionName: String,
        into tabManager: TabManager
    ) throws -> Bool {
        let key = Self.connectionKey(destination: host.destination, sessionName: sessionName)
        guard sessionMirrors[key] == nil else { return false }
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
        sessionMirrors[key] = RemoteTmuxSessionMirror(
            host: host,
            sessionName: sessionName,
            connection: connection,
            workspace: workspace
        )
        return true
    }

    // MARK: - Create / destroy propagation (P5)

    /// A new tab was requested in a mirrored workspace → create a tmux window in
    /// that session. The new tab arrives via the `%window-add` notification (one
    /// source of truth), so the caller must NOT also create a local tab.
    ///
    /// - Returns: `true` if routed to the remote (caller suppresses the local
    ///   tab); `false` if there is no live mirror/connection (caller proceeds
    ///   with normal local behavior).
    func handleMirrorNewTabRequested(workspaceId: UUID) -> Bool {
        guard let mirror = sessionMirrors.values.first(where: { $0.mirroredWorkspaceId == workspaceId }),
              !mirror.connection.exited else { return false }
        mirror.connection.send("new-window")
        return true
    }

    /// A mirrored workspace was renamed → `rename-session` on the remote so the
    /// tmux session name tracks the cmux workspace title.
    func handleMirrorWorkspaceRenamed(workspaceId: UUID, title: String?) {
        let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let entry = sessionMirrors.first(where: { $0.value.mirroredWorkspaceId == workspaceId })
        else { return }
        let mirror = entry.value
        let oldName = mirror.sessionName
        guard name != oldName, !mirror.connection.exited else { return }
        let host = mirror.host
        // Target by the stable session id when known, so the rename can't race a
        // prior rename's name.
        let target = mirror.connection.sessionId.map { "$\($0)" }
            ?? RemoteTmuxHost.shellSingleQuoted(oldName)
        mirror.connection.send("rename-session -t \(target) \(RemoteTmuxHost.shellSingleQuoted(name))")
        // Re-key all per-session state from the old name to the new one so
        // detach / kill / attach-reuse keep working after the rename.
        let oldKey = Self.connectionKey(destination: host.destination, sessionName: oldName)
        let newKey = Self.connectionKey(destination: host.destination, sessionName: name)
        mirror.setSessionName(name)
        mirror.connection.setSessionName(name)
        if oldKey != newKey {
            if let m = sessionMirrors.removeValue(forKey: oldKey) { sessionMirrors[newKey] = m }
            if let c = connectionsByHostSession.removeValue(forKey: oldKey) { connectionsByHostSession[newKey] = c }
            if let t = displayObserverTokens.removeValue(forKey: oldKey) { displayObserverTokens[newKey] = t }
        }
    }

    /// Mirror tabs were drag-reordered → reorder the tmux windows to match.
    ///
    /// Uses `swap-window` (selection-sort over the current order), NOT
    /// `move-window`: `move-window` unlinks+relinks a window, which in control
    /// mode emits `%window-close`/`%window-add` and transiently empties the
    /// mirror workspace — causing cmux to auto-seed a stray local terminal tab.
    /// `swap-window` only swaps two windows' indices (no unlink), so there is no
    /// churn. `-d` keeps the active window unchanged.
    func handleMirrorWindowsReordered(workspaceId: UUID, orderedPanelIds: [UUID]) {
        guard let mirror = sessionMirrors.values.first(where: { $0.mirroredWorkspaceId == workspaceId }),
              !mirror.connection.exited else { return }
        let desired = orderedPanelIds.compactMap { mirror.windowId(forPanel: $0) }
        guard desired.count >= 2 else { return }
        // Current tmux window order (as last reported by list-windows), restricted
        // to the windows we're reordering. Bail if the sets diverge, so we never
        // issue a swap against a window the mirror doesn't currently track.
        let desiredSet = Set(desired)
        var current = mirror.connection.windowOrder.filter { desiredSet.contains($0) }
        guard current.count == desired.count, Set(current) == desiredSet else { return }
        for index in desired.indices where current[index] != desired[index] {
            guard let swapFrom = current.firstIndex(of: desired[index]) else { continue }
            mirror.connection.send("swap-window -d -s @\(current[index]) -t @\(current[swapFrom])")
            current.swapAt(index, swapFrom)
        }
    }

    /// A split was requested from a mirrored multi-pane surface → propagate to
    /// tmux `split-window`. The new pane arrives via the resulting
    /// `%layout-change`. Returns `true` if `surfaceId` is a mirror pane (the
    /// caller suppresses the local split).
    func handleMirrorSplitRequested(surfaceId: UUID, vertical: Bool) -> Bool {
        for sessionMirror in sessionMirrors.values where !sessionMirror.connection.exited {
            if let match = sessionMirror.windowMirror(forSurfaceId: surfaceId) {
                match.mirror.requestSplit(fromPane: match.tmuxPaneId, vertical: vertical)
                return true
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

    /// A split was requested on a mirror window-tab (the split button / any
    /// bonsplit-level split) → propagate to tmux `split-window`. Covers both
    /// single-pane mirror windows and multi-pane ones. Returns `true` if handled.
    func handleMirrorTabSplitRequested(workspaceId: UUID, panelId: UUID, vertical: Bool) -> Bool {
        guard let mirror = sessionMirrors.values.first(where: { $0.mirroredWorkspaceId == workspaceId })
        else { return false }
        return mirror.requestSplit(windowPanelId: panelId, vertical: vertical)
    }

    /// A mirrored window's tab was renamed → `rename-window` on the remote.
    func handleMirrorWindowRenamed(workspaceId: UUID, panelId: UUID, title: String?) {
        let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let mirror = sessionMirrors.values.first(where: { $0.mirroredWorkspaceId == workspaceId }),
              !mirror.connection.exited,
              let windowId = mirror.windowId(forPanel: panelId) else { return }
        mirror.connection.send("rename-window -t @\(windowId) \(RemoteTmuxHost.shellSingleQuoted(name))")
    }

    /// A tab close was requested in a mirrored workspace → kill that tmux window
    /// on the remote. The local tab is removed when tmux reports `%window-close`,
    /// so the caller should VETO the immediate local close.
    ///
    /// - Returns: `true` if routed to the remote (caller vetoes the local close);
    ///   `false` if there is no live mirror/connection or the panel isn't a
    ///   mirrored window (caller proceeds with the normal local close).
    func handleMirrorTabCloseRequested(workspaceId: UUID, panelId: UUID) -> Bool {
        guard let mirror = sessionMirrors.values.first(where: { $0.mirroredWorkspaceId == workspaceId }),
              !mirror.connection.exited,
              let windowId = mirror.windowId(forPanel: panelId) else { return false }
        mirror.connection.send("kill-window -t @\(windowId)")
        return true
    }

    /// A new workspace was requested while a dedicated remote window was active →
    /// create a new tmux session on that host and mirror it into the same window.
    ///
    /// - Returns: `true` if `windowId` is a dedicated remote window (the caller
    ///   suppresses the local workspace creation); `false` otherwise.
    func handleRemoteWindowNewWorkspaceRequested(windowId: UUID) -> Bool {
        guard let destination = hostByWindowId[windowId] else { return false }
        // Recover the full host (port/identity) from an existing mirror so the
        // new session reuses the same connection details.
        let host = sessionMirrors.values.first(where: { $0.host.destination == destination })?.host
            ?? RemoteTmuxHost(destination: destination)
        guard let manager = AppDelegate.shared?.tabManagerFor(windowId: windowId) else { return true }
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
                cmuxDebugLog("remote-tmux: new-session on \(destination) failed: \(error)")
                #endif
            }
        }
        return true
    }

    /// The remote tmux session ended on its own (its last window was killed, or
    /// it was killed out-of-band) — remove the mirror + connection and close the
    /// now-dead workspace WITHOUT issuing a kill (the session is already gone).
    func handleSessionEndedRemotely(host: RemoteTmuxHost, sessionName: String, workspaceId: UUID) {
        let key = Self.connectionKey(destination: host.destination, sessionName: sessionName)
        if let mirror = sessionMirrors.removeValue(forKey: key) {
            mirror.detachObserver()
        }
        displayObserverTokens.removeValue(forKey: key)
        connectionsByHostSession.removeValue(forKey: key)?.stop()
        if !sessionMirrors.values.contains(where: { $0.host.destination == host.destination }) {
            forgetMirroredHost(host.destination)
            if let windowId = windowIdByHost.removeValue(forKey: host.destination) {
                hostByWindowId.removeValue(forKey: windowId)
            }
        }
        // Close the dead mirror workspace. The mirror was already removed above,
        // so TabManager.closeWorkspace's kill hook finds no entry and won't
        // re-issue a kill. (closeWorkspace leaves the last workspace in a window
        // for the window-close path.)
        if let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
           let workspace = manager.tabs.first(where: { $0.id == workspaceId }) {
            manager.closeWorkspace(workspace)
        }
    }

    /// Detaches any session mirrors whose workspace is in a closing window
    /// (covers the `remote.tmux.mirror` socket path that mirrors into a
    /// non-dedicated window, whose generic close doesn't run handleWorkspaceClosed).
    /// Window close = detach + preserve remote (no kill); pane surfaces are torn
    /// down via `detachObserver`.
    func handleWindowWorkspacesClosed(workspaceIds: [UUID]) {
        guard !workspaceIds.isEmpty else { return }
        let ids = Set(workspaceIds)
        for (key, mirror) in sessionMirrors {
            guard let workspaceId = mirror.mirroredWorkspaceId, ids.contains(workspaceId) else { continue }
            mirror.detachObserver()
            displayObserverTokens.removeValue(forKey: key)
            sessionMirrors.removeValue(forKey: key)
            connectionsByHostSession.removeValue(forKey: key)?.stop()
        }
    }

    /// Handles close of a dedicated remote window (Option 1): detaches every
    /// control connection for that host so the ssh clients shut down, but does
    /// NOT kill any remote session — closing the window only detaches, leaving
    /// the remote tmux server alive for resume on the next launch.
    func handleRemoteWindowClosed(windowId: UUID) {
        guard let destination = hostByWindowId[windowId] else { return }
        hostByWindowId.removeValue(forKey: windowId)
        windowIdByHost.removeValue(forKey: destination)
        for (key, mirror) in sessionMirrors where mirror.host.destination == destination {
            mirror.detachObserver()
            displayObserverTokens.removeValue(forKey: key)
            sessionMirrors.removeValue(forKey: key)
        }
        for (key, connection) in connectionsByHostSession where connection.host.destination == destination {
            connection.stop()
            connectionsByHostSession.removeValue(forKey: key)
        }
        // The host stays persisted on purpose: it re-mirrors into a fresh
        // dedicated window on the next launch.
    }

    /// Handles user-initiated close of a mirrored session workspace: detaches
    /// the control connection and kills the session on the remote.
    func handleWorkspaceClosed(workspaceId: UUID) {
        guard let entry = sessionMirrors.first(where: { $0.value.mirroredWorkspaceId == workspaceId })
        else { return }
        let mirror = entry.value
        let host = mirror.host
        let sessionName = mirror.sessionName
        sessionMirrors.removeValue(forKey: entry.key)
        mirror.detachObserver()
        displayObserverTokens.removeValue(forKey: entry.key)
        detach(host: host, sessionName: sessionName)
        // If this was the host's last mirrored session, stop auto-re-mirroring it
        // on the next launch and forget its dedicated-window binding.
        if !sessionMirrors.values.contains(where: { $0.host.destination == host.destination }) {
            forgetMirroredHost(host.destination)
            if let windowId = windowIdByHost.removeValue(forKey: host.destination) {
                hostByWindowId.removeValue(forKey: windowId)
            }
        }
        // Kill by the stable session id when known, so a prior rename-session
        // can't leave us targeting a stale name.
        let killTarget = mirror.connection.sessionId.map { "$\($0)" } ?? sessionName
        let transport = transport(for: host)
        Task { _ = try? await transport.runTmux(["kill-session", "-t", killTarget]) }
    }

    /// Returns the control connection for a host+session, if attached.
    func connection(host: RemoteTmuxHost, sessionName: String) -> RemoteTmuxControlConnection? {
        connectionsByHostSession[Self.connectionKey(
            destination: host.destination,
            sessionName: sessionName
        )]
    }

    /// Detaches and forgets a control connection (leaves the remote session alive).
    func detach(host: RemoteTmuxHost, sessionName: String) {
        let key = Self.connectionKey(destination: host.destination, sessionName: sessionName)
        connectionsByHostSession.removeValue(forKey: key)?.stop()
    }

    /// Detaches every control connection (used on app quit so remote sessions
    /// survive). Does NOT kill any remote tmux server/session.
    func detachAll() {
        let connections = Array(connectionsByHostSession.values)
        connectionsByHostSession.removeAll()
        for connection in connections { connection.stop() }
    }

    private static func connectionKey(destination: String, sessionName: String) -> String {
        "\(destination)\u{1}\(sessionName)"
    }

    // MARK: - Persistence / reconnect on relaunch (P5)

    /// JSON-encoded `[RemoteTmuxHost]` — preserves port/identityFile across launches.
    private static let mirroredHostsDefaultsKey = "remoteTmux.mirroredHostsV2"
    /// Legacy key: a plain `[String]` of destinations (destination-only). Read for
    /// one-time migration into the V2 store, then removed.
    private static let legacyMirroredHostsKey = "remoteTmux.mirroredHosts"

    /// The persisted hosts to re-mirror on launch, decoding the full host
    /// (destination + port + identityFile) or migrating the legacy
    /// destination-only array.
    private func persistedMirroredHosts() -> [RemoteTmuxHost] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.mirroredHostsDefaultsKey),
           let hosts = try? JSONDecoder().decode([RemoteTmuxHost].self, from: data) {
            return hosts
        }
        if let legacy = defaults.stringArray(forKey: Self.legacyMirroredHostsKey) {
            return legacy.map { RemoteTmuxHost(destination: $0) }
        }
        return []
    }

    private func writePersistedMirroredHosts(_ hosts: [RemoteTmuxHost]) {
        let defaults = UserDefaults.standard
        // Dedupe by destination, keep a stable order.
        var seen = Set<String>()
        let unique = hosts
            .filter { seen.insert($0.destination).inserted }
            .sorted { $0.destination < $1.destination }
        if let data = try? JSONEncoder().encode(unique) {
            defaults.set(data, forKey: Self.mirroredHostsDefaultsKey)
        }
        // The legacy store has been folded into V2; drop it so it can't shadow.
        defaults.removeObject(forKey: Self.legacyMirroredHostsKey)
    }

    /// Remembers a host (full connection details) for re-mirroring on relaunch,
    /// updating in place if its port/identity changed.
    private func addPersistedMirroredHost(_ host: RemoteTmuxHost) {
        var hosts = persistedMirroredHosts().filter { $0.destination != host.destination }
        hosts.append(host)
        writePersistedMirroredHosts(hosts)
    }

    /// Stops remembering a host so it is not re-mirrored on the next launch.
    func forgetMirroredHost(_ destination: String) {
        let hosts = persistedMirroredHosts().filter { $0.destination != destination }
        writePersistedMirroredHosts(hosts)
    }

    /// Reconnects to every persisted mirrored host and re-mirrors its
    /// still-running sessions. Quitting cmux only detaches (the remote tmux
    /// server stays alive), so this restores the sidebar after relaunch. Called
    /// once per launch from the app delegate.
    func restoreMirroredHostsOnLaunch() {
        guard Self.isEnabled else { return }
        let hosts = persistedMirroredHosts()
        guard !hosts.isEmpty else { return }
        Task { @MainActor in
            for host in hosts {
                // Restore each host into its own dedicated window (Option 1), so
                // the relaunched sidebar matches how the user attached it. Don't
                // activate — a relaunch must not steal focus.
                _ = try? await self.mirrorHostInNewWindow(host: host, activateWindow: false)
            }
        }
    }
}
