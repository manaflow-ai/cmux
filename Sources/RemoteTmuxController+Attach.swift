import Foundation

@MainActor
extension RemoteTmuxController {
    @discardableResult
    func attachHost(
        host: RemoteTmuxHost,
        windowTarget: RemoteTmuxAttachWindowTarget,
        activate: Bool
    ) async throws -> RemoteTmuxAttachOutcome {
        guard let appDelegate = AppDelegate.shared else {
            throw RemoteTmuxError.unreachable("app not ready")
        }
        let initialExistingMirrorWindowID = existingMirrorManager(for: host)
            .flatMap { appDelegate.windowId(for: $0) }
        let initialActiveWindowID = appDelegate.tabManager
            .flatMap { appDelegate.windowId(for: $0) }
        if windowTarget != .dedicatedNewWindow {
            guard windowTarget.resolve(
                existingMirrorWindowID: initialExistingMirrorWindowID,
                activeWindowID: initialActiveWindowID,
                isLive: { appDelegate.tabManagerFor(windowId: $0) != nil }
            ) != nil else {
                // Reject a guaranteed-invalid destination before discovery can
                // create a default remote session or open a cached SSH master.
                throw RemoteTmuxError.unreachable("app not ready")
            }
        }
        guard windowRegistry.beginAttach(hostHash: host.connectionHash) else {
            throw RemoteTmuxError.unreachable("already attaching \(host.destination)")
        }
        defer { windowRegistry.endAttach(hostHash: host.connectionHash) }

        let sessions: [RemoteTmuxSession]
        do {
            sessions = try await transport(for: host).discoverMirrorSessions(createIfEmpty: true)
        } catch let error as RemoteTmuxError {
            if case .commandFailed(_, let stderr) = error,
               RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr) {
                return .authRequired(sshArgv: host.interactiveAuthInvocation())
            }
            throw error
        }
        guard !sessions.isEmpty else {
            throw RemoteTmuxError.unreachable("no tmux sessions on \(host.destination)")
        }
        // Baseline for the `%sessions-changed` reconcile: sessions in this set
        // are "seen" — only sessions created after this point auto-mirror.
        discoveredSessionIdsByHost[host.connectionHash] = Set(sessions.map(\.id))
        try Task.checkCancellation()
        try await ensureControlMasterReadyForBurst(host: host)

        // Resolve stable ids after every SSH await. Explicit window routing
        // fails closed if that window disappeared; contextual routing may
        // recover to the active window. Dedicated-window requests create their
        // window only after discovery/auth preflight, so failures never leave
        // empty chrome behind.
        let resolvedWindowId: UUID
        let targetManager: TabManager
        let bootstrapWorkspaceId: UUID?
        if windowTarget == .dedicatedNewWindow {
            resolvedWindowId = appDelegate.createMainWindow(shouldActivate: false)
            guard let newWindowManager = appDelegate.tabManagerFor(windowId: resolvedWindowId) else {
                appDelegate.discardMainWindowWithoutClosedHistory(windowId: resolvedWindowId)
                cleanUpTransportAfterFailedMirror(host: host)
                throw RemoteTmuxError.windowCreationFailed
            }
            targetManager = newWindowManager
            bootstrapWorkspaceId = newWindowManager.tabs.first?.id
            moveExistingMirrors(for: host, into: newWindowManager)
        } else {
            // A live existing mirror stays first so one host cannot be split
            // across windows by a contextual or explicit attach.
            let existingMirrorWindowID = existingMirrorManager(for: host)
                .flatMap { appDelegate.windowId(for: $0) }
            let activeWindowID = appDelegate.tabManager
                .flatMap { appDelegate.windowId(for: $0) }
            guard let existingWindowId = windowTarget.resolve(
                existingMirrorWindowID: existingMirrorWindowID,
                activeWindowID: activeWindowID,
                isLive: { appDelegate.tabManagerFor(windowId: $0) != nil }
            ), let existingWindowManager = appDelegate.tabManagerFor(windowId: existingWindowId) else {
                // A valid target can close while SSH discovery is in flight. A new
                // host has no mirror owner to clean up the transport in that race.
                if initialExistingMirrorWindowID == nil {
                    transportRegistry.remove(connectionHash: host.connectionHash)
                    RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
                }
                throw RemoteTmuxError.unreachable("app not ready")
            }
            resolvedWindowId = existingWindowId
            targetManager = existingWindowManager
            bootstrapWorkspaceId = nil
        }

        let workspaceIds = mirrorDiscoveredSessions(host: host, sessions: sessions, into: targetManager)
        guard !workspaceIds.isEmpty else {
            cleanUpTransportAfterFailedMirror(host: host)
            if windowTarget == .dedicatedNewWindow {
                appDelegate.discardMainWindowWithoutClosedHistory(windowId: resolvedWindowId)
            }
            throw RemoteTmuxError.unreachable("could not mirror any tmux session on \(host.destination)")
        }

        if let bootstrapWorkspaceId,
           targetManager.tabs.count > 1,
           let bootstrap = targetManager.tabs.first(where: { $0.id == bootstrapWorkspaceId }),
           !bootstrap.isRemoteTmuxMirror {
            targetManager.closeWorkspace(bootstrap, recordHistory: false)
        }

        if activate {
            selectFirstMirrorWorkspace(for: host, in: targetManager)
            _ = appDelegate.focusMainWindow(windowId: resolvedWindowId)
        }
        return .mirrored(windowId: resolvedWindowId, workspaceIds: workspaceIds)
    }

    @discardableResult
    func mirrorDiscoveredSessions(
        host: RemoteTmuxHost,
        sessions: [RemoteTmuxSession],
        into tabManager: TabManager
    ) -> [UUID] {
        // A mirror whose workspace died without a controller-driven detach
        // must not block re-attach: its stale key makes `mirrorSessions` skip
        // recreation while the dead workspace fails the manager filter below,
        // so every retry would mirror nothing.
        purgeDeadMirrors(for: host)
        // `mirrorSessions` applies stable-session-id de-dup and seeds discovery's
        // ids into new mirrors, so bulk discovery can't duplicate a session
        // mid-rename (#7362, #7365).
        mirrorSessions(sessions, host: host, into: tabManager)
        let managerWorkspaceIds = Set(tabManager.tabs.map(\.id))
        return sessionMirrors.values.compactMap { mirror in
            guard mirror.host.connectionHash == host.connectionHash,
                  let workspaceId = mirror.mirroredWorkspaceId,
                  managerWorkspaceIds.contains(workspaceId) else { return nil }
            return workspaceId
        }
    }

    private func purgeDeadMirrors(for host: RemoteTmuxHost) {
        for (key, mirror) in sessionMirrors
        where mirror.host.connectionHash == host.connectionHash
            && mirror.mirroredWorkspaceId == nil {
            sessionMirrors.removeValue(forKey: key)
            mirror.detachObserver()
        }
    }

    /// After an attach that mirrored nothing: live mirrors in other windows
    /// still share this host's ControlMaster, so tear the transport down only
    /// when nothing live remains on the connection.
    func cleanUpTransportAfterFailedMirror(host: RemoteTmuxHost) {
        let hasLiveMirror = sessionMirrors.values.contains { mirror in
            mirror.host.connectionHash == host.connectionHash
                && mirror.mirroredWorkspaceId != nil
        }
        guard !hasLiveMirror else { return }
        transportRegistry.remove(connectionHash: host.connectionHash)
        RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
    }

    func existingMirrorManager(for host: RemoteTmuxHost) -> TabManager? {
        for mirror in sessionMirrors.values where mirror.host.connectionHash == host.connectionHash {
            guard let workspaceId = mirror.mirroredWorkspaceId,
                  let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { continue }
            return manager
        }
        return nil
    }

    /// Consolidates an existing host mirror into a newly created dedicated window.
    private func moveExistingMirrors(for host: RemoteTmuxHost, into targetManager: TabManager) {
        let hostWorkspaceIds = Set(sessionMirrors.values.compactMap { mirror -> UUID? in
            guard mirror.host.connectionHash == host.connectionHash else { return nil }
            return mirror.mirroredWorkspaceId
        })
        var sourceManagers: [TabManager] = []
        var seenSourceManagers: Set<ObjectIdentifier> = []
        for mirror in sessionMirrors.values where mirror.host.connectionHash == host.connectionHash {
            guard let workspaceId = mirror.mirroredWorkspaceId,
                  let sourceManager = mirror.mirroredWorkspace?.owningTabManager
                    ?? AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  sourceManager !== targetManager,
                  seenSourceManagers.insert(ObjectIdentifier(sourceManager)).inserted else { continue }
            sourceManagers.append(sourceManager)
        }
        for sourceManager in sourceManagers {
            let workspaces = sourceManager.tabs.filter { hostWorkspaceIds.contains($0.id) }
            for workspace in workspaces {
                guard let detached = sourceManager.detachWorkspace(tabId: workspace.id) else { continue }
                targetManager.attachWorkspace(detached, select: false)
            }
        }
    }

    /// Debounced entry for `%sessions-changed`: a session was created or
    /// destroyed somewhere on `host`'s server. Re-discovers the session set and
    /// mirrors any session that doesn't have a workspace yet, so a
    /// `tmux new-session` from a terminal appears in the sidebar without the
    /// user re-running the attach command. Destroyed sessions need no handling
    /// here — their own control client's `%exit` already tears the mirror down.
    func scheduleSessionSetReconcile(host: RemoteTmuxHost) {
        let hash = host.connectionHash
        sessionSetReconcileTasks[hash]?.cancel()
        sessionSetReconcileTasks[hash] = Task { [weak self] in
            // Collapse the per-client broadcast burst and let tmux finish
            // creating the session before discovery lists it.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.sessionSetReconcileTasks[hash] = nil
            await self.reconcileSessionSet(host: host)
        }
    }

    /// One `%sessions-changed` reconcile pass: discover the live session set and
    /// mirror the sessions NEW since the last discovery into the window already
    /// hosting this host's mirrors. Skips (rather than queues) when an explicit
    /// attach is in flight — that attach's own discovery will see the new set.
    private func reconcileSessionSet(host: RemoteTmuxHost) async {
        guard existingMirrorManager(for: host) != nil else { return }
        guard windowRegistry.beginAttach(hostHash: host.connectionHash) else { return }
        defer { windowRegistry.endAttach(hostHash: host.connectionHash) }
        // Never create a session here: an empty server means everything was
        // deliberately closed, and resurrecting a session would fight the
        // kill-on-close teardown.
        guard let sessions = try? await transport(for: host).discoverMirrorSessions(createIfEmpty: false),
              !sessions.isEmpty else { return }
        let hash = host.connectionHash
        let previouslySeen = discoveredSessionIdsByHost[hash] ?? []
        discoveredSessionIdsByHost[hash] = Set(sessions.map(\.id))
        // Only sessions the user hasn't seen before: re-mirroring a known
        // session would resurrect a workspace they deliberately detached.
        let fresh = sessions.filter { !previouslySeen.contains($0.id) }
        guard !fresh.isEmpty else { return }
        // Re-resolve after the await: the mirror window can close mid-discovery.
        guard let manager = existingMirrorManager(for: host) else { return }
        mirrorDiscoveredSessions(host: host, sessions: fresh, into: manager)
    }

    /// Routes a user's plain "New Workspace" to the LOCAL tmux server when the
    /// window's selected workspace mirrors it: the new workspace is then a real
    /// `tmux new-session` (mirrored and two-way synced) instead of an unsynced
    /// local orphan — the workspace-level counterpart of the in-mirror new-tab
    /// routing that already lands on `new-window`.
    ///
    /// Returns `true` when the request was taken over (creation continues
    /// asynchronously); `false` means the caller creates a plain workspace.
    /// Gated on the SELECTED workspace, matching the sidebar's mirror routing:
    /// dedicated mirror windows can contain dragged-in local workspaces, and a
    /// user working in one of those keeps plain semantics.
    @discardableResult
    func routeNewWorkspaceToLocalTmux(in manager: TabManager) -> Bool {
        guard Self.isEnabled else { return false }
        guard let selected = manager.selectedTab,
              selected.isRemoteTmuxMirror,
              let mirror = sessionMirrors.values.first(where: { $0.mirroredWorkspaceId == selected.id }),
              mirror.host.isLocal else { return false }
        Task { [weak self] in
            await self?.createAndMirrorLocalSession(in: manager)
        }
        return true
    }

    /// Creates a detached session on the local tmux server, mirrors it into
    /// `manager` as a new workspace, and selects it. Falls back to a plain
    /// workspace on any failure so the user's "New Workspace" never silently
    /// does nothing.
    private func createAndMirrorLocalSession(in manager: TabManager) async {
        let host = RemoteTmuxHost.local
        func fallbackToPlainWorkspace() {
            guard AppDelegate.shared?.windowId(for: manager) != nil else { return }
            manager.addWorkspace()
        }
        guard let created = try? await transport(for: host).runTmux(
            ["new-session", "-d", "-P", "-F", "#{session_id}"]
                + RemoteTmuxSSHTransport.localStartDirectoryArgs(host: host)
        ), created.succeeded else {
            fallbackToPlainWorkspace()
            return
        }
        let newSessionId = created.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newSessionId.isEmpty,
              let sessions = try? await transport(for: host).discoverMirrorSessions(createIfEmpty: false),
              let session = sessions.first(where: { $0.id == newSessionId }) else {
            fallbackToPlainWorkspace()
            return
        }
        // Mark seen so the `%sessions-changed` reconcile this creation also
        // triggers treats the session as handled (mirroring is idempotent
        // regardless — this just avoids a redundant pass).
        discoveredSessionIdsByHost[host.connectionHash, default: []].insert(session.id)
        // The window can close across the awaits.
        guard AppDelegate.shared?.windowId(for: manager) != nil else { return }
        mirrorDiscoveredSessions(host: host, sessions: [session], into: manager)
        let key = Self.connectionKey(host: host, sessionName: session.name)
        if let workspace = sessionMirrors[key]?.mirroredWorkspace {
            manager.selectWorkspace(workspace)
        }
    }

    private func selectFirstMirrorWorkspace(for host: RemoteTmuxHost, in tabManager: TabManager) {
        let hostWorkspaceIds = Set(sessionMirrors.values.compactMap { mirror -> UUID? in
            guard mirror.host.connectionHash == host.connectionHash else { return nil }
            return mirror.mirroredWorkspaceId
        })
        guard let workspace = tabManager.tabs.first(where: { hostWorkspaceIds.contains($0.id) }) else { return }
        tabManager.selectWorkspace(workspace)
    }

}
