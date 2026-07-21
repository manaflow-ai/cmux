import CmuxSettings
import Foundation

/// Multiplexer transport: one shared `tmux -CC` view stream per host.
///
/// For hosts that permit only a single concurrent SSH connection/session, the GA
/// per-session connections cannot coexist — the first `-CC` attach occupies the
/// only channel and every later session's attach falls back to a fresh connection
/// the host refuses (or demands interactive auth for). In this mode ONE
/// ``RemoteTmuxViewConnection`` attaches to a hidden per-install view session,
/// every real session's windows are linked into it, and each session is mirrored
/// through a ``RemoteTmuxSessionChannel`` scoping that single stream. The
/// workspace model is identical to GA: one workspace per session, windows as tabs.
@MainActor
extension RemoteTmuxController {
    /// Transport selection: when true, a host's sessions are mirrored over ONE shared
    /// `tmux -CC` view connection; when false (default), each session gets its own
    /// connection (GA). An explicit mode flag, not a runtime auto-switch — the
    /// workspace model is identical either way.
    /// Resolves the same catalog key the settings store persists to, so the
    /// catalog stays the single source of the key, decode, and default —
    /// identical shape to ``isEnabled``.
    nonisolated static var isMultiplexerEnabled: Bool {
        let key = SettingCatalog().betaFeatures.remoteTmuxMultiplexer
        return Bool.decodeFromUserDefaults(UserDefaults.standard.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    /// A stable per-install owner id for cmux's hidden view sessions, persisted in
    /// UserDefaults so the same cmux reattaches its own views across relaunch and
    /// never collides with another install's.
    static var multiplexerOwnerId: String {
        let defaultsKey = "remoteTmux.multiplexer.ownerId"
        if let existing = UserDefaults.standard.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: defaultsKey)
        return fresh
    }

    /// Whether a mirror is served by the shared view connection (multiplexed) rather
    /// than a dedicated per-session connection (GA).
    func isMultiplexed(_ mirror: RemoteTmuxSessionMirror) -> Bool {
        mirror.connection is RemoteTmuxSessionChannel
    }

    /// Whether `host` still has any live session mirror (either transport).
    func hostHasLiveMirror(_ host: RemoteTmuxHost) -> Bool {
        sessionMirrors.values.contains { $0.host.connectionHash == host.connectionHash }
    }

    /// A live dedicated-transport mirror on the host conflicts with the shared view
    /// transport: both own the same `sessionMirrors` key space but use incompatible
    /// connection lifecycles.
    func hostHasDedicatedMirror(_ host: RemoteTmuxHost) -> Bool {
        sessionMirrors.values.contains {
            $0.host.connectionHash == host.connectionHash && !isMultiplexed($0)
        }
    }

    func storeMultiplexIntents(
        _ intents: RemoteTmuxMultiplexReconciler.Intents,
        hostHash: String
    ) {
        multiplexIntentsByHost[hostHash] = intents.isEmpty ? nil : intents
    }

    func recordMultiplexIntent(
        _ ref: RemoteTmuxMultiplexReconciler.SessionRef,
        kill: Bool,
        hostHash: String
    ) {
        var intents = multiplexIntentsByHost[hostHash] ?? .init()
        if kill {
            if !intents.pendingKills.contains(ref) { intents.pendingKills.append(ref) }
        } else if !intents.detached.contains(ref) {
            intents.detached.append(ref)
        }
        storeMultiplexIntents(intents, hostHash: hostHash)
    }

    /// A changed hidden-view `$id` means tmux restarted and may have reused session ids;
    /// all id-scoped intents from the old server epoch are unsafe to apply.
    nonisolated static func shouldResetEpoch(recorded: Int?, current: Int?) -> Bool {
        guard let recorded, let current else { return false }
        return recorded != current
    }

    func updateMultiplexEpochIfNeeded(hostHash: String, current: Int?) {
        if Self.shouldResetEpoch(recorded: viewEpochSessionIdByHost[hostHash], current: current) {
            multiplexIntentsByHost[hostHash] = nil
        }
        if let current { viewEpochSessionIdByHost[hostHash] = current }
    }

    func configureMultiplexChannel(_ channel: RemoteTmuxSessionChannel, host: RemoteTmuxHost) {
        channel.coordinator = multiplexedViewsByHost[host.connectionHash]
        channel.onEndSessionIntent = { [weak self] ref, kill in
            self?.recordMultiplexIntent(ref, kill: kill, hostHash: host.connectionHash)
        }
    }

    /// Detaches a multiplexed mirror's channel (releasing its shared-stream observer)
    /// and removes both the channel and the mirror from the registries. Returns the
    /// removed mirror so the caller can close its workspace.
    @discardableResult
    func teardownMultiplexedMirror(key: String) -> RemoteTmuxSessionMirror? {
        channelsByHostSession.removeValue(forKey: key)?.releaseMirror()
        guard let mirror = sessionMirrors.removeValue(forKey: key) else { return nil }
        mirror.detachObserver()
        return mirror
    }

    /// The multiplexed analogue of ``attachHost(host:windowTarget:activate:)``:
    /// discovery + auth classification stay identical (sequential one-shots are safe
    /// before any `-CC` client holds the host's single session), then ONE shared view
    /// connection comes up and its reconcile builds the per-session workspaces.
    func attachHostMultiplexed(
        host: RemoteTmuxHost,
        windowTarget: RemoteTmuxAttachWindowTarget,
        activate: Bool
    ) async throws -> RemoteTmuxAttachOutcome {
        guard let appDelegate = AppDelegate.shared else {
            throw RemoteTmuxError.unreachable("app not ready")
        }
        if hostHasDedicatedMirror(host) {
            throw RemoteTmuxError.unreachable(
                "host already mirrored by the per-session transport; detach it first")
        }

        let beganAttach = windowRegistry.beginAttach(hostHash: host.connectionHash)
        if !beganAttach {
            guard let view = multiplexedViewsByHost[host.connectionHash] else {
                throw RemoteTmuxError.unreachable("already attaching \(host.destination)")
            }
            _ = await view.awaitFirstWorkspaces(timeout: 30)
            let existingMirrorWindowID = existingMirrorManager(for: host)
                .flatMap { appDelegate.windowId(for: $0) }
            let activeWindowID = appDelegate.tabManager
                .flatMap { appDelegate.windowId(for: $0) }
            guard let resolvedWindowId = windowTarget.resolve(
                existingMirrorWindowID: existingMirrorWindowID,
                activeWindowID: activeWindowID,
                isLive: { appDelegate.tabManagerFor(windowId: $0) != nil }
            ), let targetManager = appDelegate.tabManagerFor(windowId: resolvedWindowId) else {
                throw RemoteTmuxError.unreachable("app not ready")
            }
            if !hostHasLiveMirror(host), let shared = view.connection {
                applyMultiplexedWorkspaces(
                    host: host, manager: targetManager, workspaces: view.workspaces, shared: shared)
            }
            let workspaceIds = sessionMirrors.values.compactMap { mirror -> UUID? in
                guard mirror.host.connectionHash == host.connectionHash else { return nil }
                return mirror.mirroredWorkspaceId
            }
            guard !workspaceIds.isEmpty else {
                throw RemoteTmuxError.unreachable("could not mirror any tmux session on \(host.destination)")
            }
            if activate {
                selectFirstMirrorWorkspace(for: host, in: targetManager)
                _ = appDelegate.focusMainWindow(windowId: resolvedWindowId)
            }
            return .mirrored(windowId: resolvedWindowId, workspaceIds: workspaceIds)
        }
        defer { windowRegistry.endAttach(hostHash: host.connectionHash) }

        // Auth classification via the same one-shot the GA path uses (BatchMode over
        // the shared master): an interactive-auth failure routes the CLI to its
        // foreground handoff. `createIfEmpty: false` — the view coordinator has its
        // own session-less-host bootstrap.
        do {
            _ = try await transport(for: host).discoverMirrorSessions(createIfEmpty: false)
        } catch let error as RemoteTmuxError {
            if case .commandFailed(_, let stderr) = error,
               RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr) {
                return .authRequired(sshArgv: host.interactiveAuthInvocation())
            }
            throw error
        }
        try Task.checkCancellation()
        try await ensureControlMasterReadyForBurst(host: host)

        let existingMirrorWindowID = existingMirrorManager(for: host)
            .flatMap { appDelegate.windowId(for: $0) }
        let activeWindowID = appDelegate.tabManager
            .flatMap { appDelegate.windowId(for: $0) }
        guard let resolvedWindowId = windowTarget.resolve(
            existingMirrorWindowID: existingMirrorWindowID,
            activeWindowID: activeWindowID,
            isLive: { appDelegate.tabManagerFor(windowId: $0) != nil }
        ), let targetManager = appDelegate.tabManagerFor(windowId: resolvedWindowId) else {
            if existingMirrorWindowID == nil, multiplexedViewsByHost[host.connectionHash] == nil {
                transportRegistry.remove(connectionHash: host.connectionHash)
                RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
            }
            throw RemoteTmuxError.unreachable("app not ready")
        }

        // Reuse a live view: the host is already mirrored; just surface it.
        if multiplexedViewsByHost[host.connectionHash] == nil {
            try await startMultiplexedHost(host: host, manager: targetManager)
        }

        // The first reconcile lands asynchronously once the stream reports
        // `%enter`; await its publication signal so the caller gets real
        // workspace ids and the CLI's summary isn't a lie. Event-driven with a
        // generous deadline as a last resort only — a session-less host's
        // bootstrap legitimately needs several round trips, and a premature
        // timeout here would tear down a connection that was about to succeed.
        if !hostHasLiveMirror(host), let view = multiplexedViewsByHost[host.connectionHash] {
            _ = await view.awaitFirstWorkspaces(timeout: 30)
            if !hostHasLiveMirror(host), let shared = view.connection {
                applyMultiplexedWorkspaces(
                    host: host, manager: targetManager, workspaces: view.workspaces, shared: shared)
            }
        }
        let workspaceIds = sessionMirrors.values.compactMap { mirror -> UUID? in
            guard mirror.host.connectionHash == host.connectionHash else { return nil }
            return mirror.mirroredWorkspaceId
        }
        guard !workspaceIds.isEmpty else {
            stopMultiplexedHost(host: host)
            throw RemoteTmuxError.unreachable("could not mirror any tmux session on \(host.destination)")
        }
        if activate {
            selectFirstMirrorWorkspace(for: host, in: targetManager)
            _ = appDelegate.focusMainWindow(windowId: resolvedWindowId)
        }
        return .mirrored(windowId: resolvedWindowId, workspaceIds: workspaceIds)
    }

    /// Brings up the host's single shared view connection and wires its reconcile to
    /// build/rescope/tear down the per-session mirrors. Stores the view before the
    /// throwing `start()` so a failed launch is torn down via ``stopMultiplexedHost(host:)``.
    func startMultiplexedHost(host: RemoteTmuxHost, manager: TabManager) async throws {
        let view = RemoteTmuxViewConnection(
            host: host, ownerId: Self.multiplexerOwnerId, transport: transport(for: host))
        view.onWorkspacesChanged = { [weak self, weak manager, weak view] in
            guard let self, let view, let shared = view.connection else { return }
            // Prefer the manager the host's mirrors CURRENTLY live in: the
            // attach-time window can close (or the workspaces be dragged away)
            // while the view lives on, and the reconcile must keep applying.
            guard let target = self.existingMirrorManager(for: host) ?? manager else { return }
            self.applyMultiplexedWorkspaces(
                host: host, manager: target, workspaces: view.workspaces, shared: shared)
        }
        view.onEnded = { [weak self] in
            self?.teardownMultiplexedHost(host: host)
        }
        // Same login path the GA (one-connection-per-session) mirrors use. Without this a
        // multiplexed host that parks on authentication offers no login at all and every session
        // on it stays frozen, because the parked stream is the shared view connection rather than
        // any one session's own.
        view.onAuthRequired = { [weak self] sshArgv in
            self?.presentReconnectAuthentication(host: host, sshArgv: sshArgv) ?? false
        }
        multiplexedViewsByHost[host.connectionHash] = view
        do {
            try await view.start()
        } catch {
            stopMultiplexedHost(host: host)
            throw error
        }
    }

    /// Reconciles the host's cmux workspaces + channels against the view connection's
    /// published workspaces: creates a channel + workspace + mirror for each new home
    /// session, rescopes existing channels (a new tab adds a window id), and tears
    /// down those whose session is gone. All mirrors share the host's one view
    /// connection via their channels.
    ///
    /// Takes the published `workspaces` and the `shared` stream as parameters (the
    /// view's change callback passes its live values) so the whole reconcile is
    /// drivable from data in tests — no view state to reach into.
    func applyMultiplexedWorkspaces(
        host: RemoteTmuxHost,
        manager: TabManager,
        workspaces: [RemoteTmuxLinkedWorkspaceModel.Workspace],
        shared: RemoteTmuxControlConnection
    ) {
        let hostHash = host.connectionHash
        updateMultiplexEpochIfNeeded(hostHash: hostHash, current: shared.sessionId)
        // No real sessions remain (e.g. the last was killed out-of-band): tear the
        // view down and close the mirrors' workspaces, matching GA's last-session-end.
        if workspaces.isEmpty {
            teardownMultiplexedHost(host: host)
            return
        }

        // Include dedicated mirrors too so a mid-flight mode conflict can never let
        // a multiplexed create overwrite an existing GA key. Apply steps below still
        // mutate only multiplexed mirrors.
        let existingMirrors = sessionMirrors.values
            .filter { $0.host.connectionHash == hostHash }
            .map { mirror in
                RemoteTmuxMultiplexReconciler.ExistingMirror(
                    sessionName: mirror.sessionName,
                    sessionId: mirror.connection.sessionId ?? mirror.seededSessionId,
                    windowIds: (mirror.connection as? RemoteTmuxSessionChannel)?.windowIds
                        ?? mirror.connection.windowOrder
                )
            }
        let incomingIntents = multiplexIntentsByHost[hostHash] ?? .init()
        let result = RemoteTmuxMultiplexReconciler.plan(
            workspaces: workspaces,
            existingMirrors: existingMirrors,
            intents: incomingIntents
        )
        let plan = result.plan
        storeMultiplexIntents(result.survivingIntents, hostHash: hostHash)

        if let view = multiplexedViewsByHost[hostHash] {
            for ref in plan.killRetries { view.killWorkspaceSession(ref) }
        }

        // A rename target can be occupied by a stale mirror that this same plan will
        // remove (old session renamed while a new session reused its old name). Clear
        // removals first so the two-phase rename guard only sees real collisions.
        for name in plan.remove {
            let key = Self.connectionKey(host: host, sessionName: name)
            guard let mirror = sessionMirrors[key], isMultiplexed(mirror) else { continue }
            _ = teardownMultiplexedMirror(key: key)
            closeDeadMirrorWorkspace(mirror.mirroredWorkspace, recordHistory: false)
        }
        applyMultiplexedRenames(host: host, renames: plan.rename)

        for sessionView in plan.update {
            let key = Self.connectionKey(host: host, sessionName: sessionView.sessionName)
            guard let channel = channelsByHostSession[key]
                    ?? (sessionMirrors[key]?.connection as? RemoteTmuxSessionChannel) else { continue }
            channelsByHostSession[key] = channel
            // The id can arrive later than the mirror (a channel created from a
            // pre-id snapshot starts with nil); never clobber a known id with nil —
            // it is the rename identity, and losing it would demote the next
            // rename back to remove+create.
            if let sessionId = sessionView.sessionId { channel.setScopedSessionId(sessionId) }
            channel.updateWindowIds(sessionView.windowIds)
        }
        for create in plan.create {
            let sessionView = create.view
            let key = Self.connectionKey(host: host, sessionName: sessionView.sessionName)
            guard sessionMirrors[key] == nil else { continue }
            // Select ONLY the session a user-initiated New Workspace created, and
            // only if the user is still on the tab the action originated from —
            // an unrelated session surfacing first must never steal focus.
            let selectNewlyCreated = create.select
                && incomingIntents.pendingSelect.map { manager.selectedTab?.id == $0.originatingTabId } == true
            let channel = RemoteTmuxSessionChannel(
                underlying: shared,
                sessionName: sessionView.sessionName,
                sessionId: sessionView.sessionId,
                windowIds: sessionView.windowIds)
            channel.sharedStream = shared
            configureMultiplexChannel(channel, host: host)
            channelsByHostSession[key] = channel
            createMirrorWorkspace(
                host: host,
                sessionName: sessionView.sessionName,
                sessionId: sessionView.sessionId,
                connection: channel,
                into: manager,
                select: selectNewlyCreated
            )
        }
    }

    /// Re-keys live multiplexed mirrors after remote `rename-session` events. All old
    /// keys are removed before any new key is inserted, so a two-session name swap
    /// cannot collide and strand one mirror under the other's key.
    func applyMultiplexedRenames(
        host: RemoteTmuxHost,
        renames: [RemoteTmuxMultiplexReconciler.Rename]
    ) {
        guard !renames.isEmpty else { return }
        struct Move {
            var oldKey: String
            var newKey: String
            var rename: RemoteTmuxMultiplexReconciler.Rename
            var mirror: RemoteTmuxSessionMirror
            var channel: RemoteTmuxSessionChannel?
        }
        let oldKeys = Set(renames.map { Self.connectionKey(host: host, sessionName: $0.oldName) })
        var moves: [Move] = []
        for rename in renames {
            let newName = rename.view.sessionName
            let oldKey = Self.connectionKey(host: host, sessionName: rename.oldName)
            let newKey = Self.connectionKey(host: host, sessionName: newName)
            guard oldKey != newKey else { continue }
            guard sessionMirrors[newKey] == nil || oldKeys.contains(newKey) else { continue }
            guard let mirror = sessionMirrors[oldKey], isMultiplexed(mirror) else { continue }
            moves.append(Move(
                oldKey: oldKey,
                newKey: newKey,
                rename: rename,
                mirror: mirror,
                channel: channelsByHostSession[oldKey]
                    ?? (mirror.connection as? RemoteTmuxSessionChannel)
            ))
        }
        for move in moves {
            sessionMirrors[move.oldKey] = nil
            channelsByHostSession[move.oldKey] = nil
        }
        for move in moves {
            let newName = move.rename.view.sessionName
            sessionMirrors[move.newKey] = move.mirror
            if let channel = move.channel {
                channelsByHostSession[move.newKey] = channel
                channel.setSessionName(newName)
                if let sessionId = move.rename.view.sessionId { channel.setScopedSessionId(sessionId) }
                channel.updateWindowIds(move.rename.view.windowIds)
                configureMultiplexChannel(channel, host: host)
            }
            move.mirror.setSessionName(newName)
            move.mirror.applySessionNameToWorkspaceTitle(newName)
        }
    }

    /// Stops a host's view connection and removes its channels + mirrors WITHOUT
    /// closing their workspaces. Drops the shared transport/master when no mirror
    /// still needs it. Returns `true` if a view was present.
    @discardableResult
    func stopMultiplexedHost(host: RemoteTmuxHost) -> Bool {
        guard multiplexedViewsByHost[host.connectionHash] != nil else { return false }
        // Collect keys first — `teardownMultiplexedMirror` mutates `sessionMirrors`.
        let keys = sessionMirrors
            .filter { $0.value.host.connectionHash == host.connectionHash && isMultiplexed($0.value) }
            .map(\.key)
        for key in keys { teardownMultiplexedMirror(key: key) }
        multiplexedViewsByHost[host.connectionHash]?.stop()
        multiplexedViewsByHost[host.connectionHash] = nil
        multiplexIntentsByHost[host.connectionHash] = nil
        viewEpochSessionIdByHost[host.connectionHash] = nil
        // Fail any `new-remote-workspace` awaiting a session on this host that never
        // surfaced, so its caller returns instead of waiting out the full deadline.
        let hostKeyPrefix = host.connectionHash + "\u{1}"
        for key in newWorkspaceWaiters.keys where key.hasPrefix(hostKeyPrefix) {
            resolveNewWorkspaceWaiters(key: key, workspaceId: nil)
        }
        if !multiplexerHostStillInUse(host) {
            transportRegistry.remove(connectionHash: host.connectionHash)
            RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
        }
        return true
    }

    /// Whether `host`'s shared transport/master is still needed by any live mirror in
    /// either mode — guards transport teardown so ending one mode doesn't pull the
    /// master from under the other (possible if the flag is toggled mid-session).
    func multiplexerHostStillInUse(_ host: RemoteTmuxHost) -> Bool {
        // The caller (stopMultiplexedHost) has already removed the host's view,
        // so "still in use" is exactly: a live mirror (either transport) or a
        // cached dedicated connection sharing the master.
        hostHasLiveMirror(host) || hasCachedConnection(hostHash: host.connectionHash)
    }

    /// Tears down a host's view connection + all its mirrors (the view stream ended
    /// for good, or its last session closed) and closes their now-dead workspaces.
    /// Unlike the dedicated-window era there is no window to discard — mirrors live
    /// in the user's own window.
    func teardownMultiplexedHost(host: RemoteTmuxHost) {
        // Capture workspace ids before stop drops the mirrors, then stop FIRST so the
        // closes below can't re-enter a kill path (no mirror found → no-op).
        let deadWorkspaces = sessionMirrors.values
            .filter { $0.host.connectionHash == host.connectionHash && isMultiplexed($0) }
            .compactMap(\.mirroredWorkspace)
        stopMultiplexedHost(host: host)
        for workspace in deadWorkspaces {
            closeDeadMirrorWorkspace(workspace, recordHistory: false)
        }
    }

    /// Closes a mirror workspace whose remote backing is gone or detached,
    /// honoring the keep-open conversion and never stranding a windowless
    /// window (`closeWorkspace` refuses to remove a window's last workspace, so
    /// a fresh local one is added first). Resolves the workspace's CURRENT
    /// manager, so a dragged-out workspace still closes.
    func closeDeadMirrorWorkspace(_ workspace: Workspace?, recordHistory: Bool = true) {
        guard let workspace, workspace.isRemoteTmuxMirror else { return }
        // The workspace's own manager first — the same resolution the dedicated
        // transport's teardown uses — with the window-context lookup as the
        // fallback for a workspace that was dragged mid-teardown.
        guard let manager = workspace.owningTabManager
                ?? AppDelegate.shared?.tabManagerFor(tabId: workspace.id) else { return }
        if workspace.handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded() { return }
        if manager.tabs.count == 1 {
            _ = manager.addWorkspace(inheritWorkingDirectory: false, select: false)
        }
        manager.closeWorkspace(workspace, recordHistory: recordHistory)
    }
}
