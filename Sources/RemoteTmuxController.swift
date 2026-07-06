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
                cmuxDebugLog("remote-tmux: mirror session \(session.name) on \(host.destination) failed: \(error)")
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
        into tabManager: TabManager
    ) throws -> Bool {
        let key = Self.connectionKey(host: host, sessionName: sessionName)
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
            seededSessionId: sessionId,
            connection: connection,
            tabManager: tabManager,
            workspace: workspace
        )
        return true
    }

    // MARK: - Create / destroy propagation (P5)

    /// A new tab was requested in a mirrored workspace → create a tmux window in
    /// that session. The new tab arrives via the `%window-add` notification (one
    /// source of truth), so the caller must NOT also create a local tab.
    ///
    /// `placement` mirrors cmux's `newTabPosition` for the workspace tab strip so
    /// a remote new tab lands where a local one would (after the selected tab, or
    /// at the end), instead of wherever tmux's bare `new-window` picks (the lowest
    /// free index, which lands mid-list when the session has window-index gaps).
    ///
    /// Requires a live `.connected` stream — NOT just `!exited`: while
    /// reconnecting there is no stdin and `send` silently drops the command, so
    /// returning `true` would let socket callers report an accepted mutation
    /// that never reached tmux.
    ///
    /// - Parameter workingDirectory: the directory the new tmux window should
    ///   start in (the active tab's cwd, resolved by the caller), so a new tab
    ///   inherits the active tab's directory the way local cmux does. A
    ///   nil/blank/unsafe value, or a source panel that is not backed by a live
    ///   mirror window, omits `-c` and lets tmux pick its default-path.
    /// - Returns: `true` if routed to the remote; `false` if there is no live
    ///   mirror/connection (callers must still NOT create a local tab in a
    ///   mirror workspace — they report failure instead).
    func handleMirrorNewTabRequested(
        workspaceId: UUID,
        placement: RemoteTmuxMirrorNewTabPlacement,
        workingDirectory: String?,
        workingDirectorySourcePanelId: UUID?
    ) -> Bool {
        guard let mirror = sessionMirrors.values.first(where: { $0.mirroredWorkspaceId == workspaceId }),
              mirror.connection.connectionState == .connected else { return false }
        let afterWindowId: Int?
        switch placement {
        case .end:
            afterWindowId = nil
        case .afterPanel(let panelId):
            // nil (panel has no live window) falls back to end placement.
            afterWindowId = mirror.windowId(forPanel: panelId)
        }
        let commandWorkingDirectory = Self.liveMirrorWindowWorkingDirectory(
            workingDirectory,
            sourcePanelId: workingDirectorySourcePanelId,
            windowIdForPanel: mirror.windowId(forPanel:)
        )
        return mirror.connection.send(
            Self.newWindowCommand(afterWindowId: afterWindowId, workingDirectory: commandWorkingDirectory)
        )
    }

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
              mirror.connection.connectionState == .connected else { return }
        let desired = orderedPanelIds.compactMap { mirror.windowId(forPanel: $0) }
        guard desired.count >= 2 else { return }
        // Current tmux window order (as last reported by list-windows), restricted
        // to the windows we're reordering. Bail if the sets diverge, so we never
        // issue a swap against a window the mirror doesn't currently track.
        let desiredSet = Set(desired)
        var current = mirror.connection.windowOrder.filter { desiredSet.contains($0) }
        guard current.count == desired.count, Set(current) == desiredSet else { return }
        var swapped = false
        for index in desired.indices where current[index] != desired[index] {
            guard let swapFrom = current.firstIndex(of: desired[index]) else { continue }
            guard mirror.connection.send("swap-window -d -s @\(current[index]) -t @\(current[swapFrom])") else {
                return
            }
            current.swapAt(index, swapFrom)
            swapped = true
        }
        // `swap-window` changes window indices but emits no notification cmux
        // re-reads the order from, so update the tracked order locally. The swaps
        // achieve exactly `desired`, so this matches tmux and a rapid follow-up
        // drag computes against the just-applied order. (Deliberately NOT a
        // `requestWindows()` re-fetch: its async snapshot could land after a later
        // reorder and roll the order back, reintroducing the race; out-of-band
        // changes reconcile on the topology events that re-fetch anyway.)
        if swapped { mirror.connection.applyWindowReorder(desired) }
    }

    /// A split was requested from a mirrored multi-pane surface → propagate to
    /// tmux `split-window`. The new pane arrives via the resulting
    /// `%layout-change`. Returns `true` if `surfaceId` is a mirror pane (the
    /// caller suppresses the local split).
    func handleMirrorSplitRequested(surfaceId: UUID, vertical: Bool) -> Bool {
        for sessionMirror in sessionMirrors.values {
            if let match = sessionMirror.windowMirror(forSurfaceId: surfaceId) {
                return match.mirror.requestSplit(fromPane: match.tmuxPaneId, vertical: vertical)
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
        -> (connection: RemoteTmuxControlConnection, paneId: Int)?
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
        tearDownMirrorAndCloseWorkspace(host: host, sessionName: sessionName, workspaceId: workspaceId)
    }

    /// Removes a mirror + its control connection, then closes or converts the local
    /// workspace. Shared by remote session-end and deliberate detach; neither kills.
    private func tearDownMirrorAndCloseWorkspace(
        host: RemoteTmuxHost,
        sessionName: String,
        workspaceId: UUID
    ) {
        let key = Self.connectionKey(host: host, sessionName: sessionName)
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
            "remote-tmux: session ended host=\(host.destination) session=\(sessionName) " +
            "hostHasOtherMirrors=\(hostHasOtherMirrors)"
        )
        #endif
        if (mirrorWorkspace ?? AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?
            .tabs.first(where: { $0.id == workspaceId }))?
            .handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded() == true { return }
        // Close just the dead workspace. `closeWorkspace` refuses to remove a
        // window's last workspace (it would leave a windowless state), so if the
        // dead mirror is the only workspace in its window, add a fresh local
        // workspace first — that leaves a usable window instead of stranding a
        // frozen, connection-less remote tab. `inheritWorkingDirectory: false`
        // avoids inheriting the mirror's remote path; `select: false` keeps the
        // disconnect from stealing focus (closeWorkspace reselects after the
        // dead one is removed).
        let manager = mirrorWorkspace?.owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
        let workspace = mirrorWorkspace ?? manager?.tabs.first(where: { $0.id == workspaceId })
        if let manager, let workspace {
            if manager.tabs.count == 1 {
                _ = manager.addWorkspace(inheritWorkingDirectory: false, select: false)
            }
            manager.closeWorkspace(workspace)
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
            mirror.detachObserver()
            sessionMirrors.removeValue(forKey: key)
            removeCachedConnection(forKey: key)?.stop()
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
    func connection(host: RemoteTmuxHost, sessionName: String) -> RemoteTmuxControlConnection? {
        connectionsByHostSession[Self.connectionKey(
            host: host,
            sessionName: sessionName
        )]
    }

    /// Detaches a control client and removes its mirror workspace while leaving
    /// the remote session alive (#7364). Internal callers that already removed the
    /// mirror keep the low-level stop-only path, preserving their kill semantics.
    func detach(host: RemoteTmuxHost, sessionName: String) {
        let key = Self.connectionKey(host: host, sessionName: sessionName)
        if let workspaceId = sessionMirrors[key]?.mirroredWorkspaceId {
            tearDownMirrorAndCloseWorkspace(host: host, sessionName: sessionName, workspaceId: workspaceId)
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
