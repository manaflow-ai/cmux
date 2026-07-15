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

    private func selectFirstMirrorWorkspace(for host: RemoteTmuxHost, in tabManager: TabManager) {
        let hostWorkspaceIds = Set(sessionMirrors.values.compactMap { mirror -> UUID? in
            guard mirror.host.connectionHash == host.connectionHash else { return nil }
            return mirror.mirroredWorkspaceId
        })
        guard let workspace = tabManager.tabs.first(where: { hostWorkspaceIds.contains($0.id) }) else { return }
        tabManager.selectWorkspace(workspace)
    }

}
