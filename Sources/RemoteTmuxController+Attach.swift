import Foundation

@MainActor
extension RemoteTmuxController {
    @discardableResult
    func attachHost(
        host: RemoteTmuxHost,
        into requestedManager: TabManager?,
        activate: Bool
    ) async throws -> RemoteTmuxAttachOutcome {
        guard let appDelegate = AppDelegate.shared else {
            throw RemoteTmuxError.unreachable("app not ready")
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

        // Post-await re-resolve: prefer the manager already hosting this host's
        // mirrors, then the dispatch-time requested manager — but only while its
        // window is still open (a mid-flight close must not mirror into a dead
        // manager) — then the key window.
        let targetManager = existingMirrorManager(for: host)
            ?? (requestedManager?.window != nil ? requestedManager : nil)
            ?? appDelegate.tabManager
        guard let targetManager else {
            throw RemoteTmuxError.unreachable("app not ready")
        }

        let workspaceIds = mirrorDiscoveredSessions(host: host, sessions: sessions, into: targetManager)
        guard !workspaceIds.isEmpty else {
            transportRegistry.remove(connectionHash: host.connectionHash)
            RemoteTmuxSSHTransport.spawnControlMasterExit(host: host)
            throw RemoteTmuxError.unreachable("could not mirror any tmux session on \(host.destination)")
        }

        let resolvedWindowId = appDelegate.windowId(for: targetManager)
            ?? workspaceIds.lazy.compactMap { appDelegate.tabManagerFor(tabId: $0) }.compactMap { appDelegate.windowId(for: $0) }.first
            ?? appDelegate.tabManager.flatMap { appDelegate.windowId(for: $0) }
        if activate, let windowId = resolvedWindowId {
            selectFirstMirrorWorkspace(for: host, in: targetManager)
            _ = appDelegate.focusMainWindow(windowId: windowId)
        }
        return .mirrored(windowId: resolvedWindowId ?? Self.unresolvedMirrorWindowId, workspaceIds: workspaceIds)
    }

    @discardableResult
    func mirrorDiscoveredSessions(
        host: RemoteTmuxHost,
        sessions: [RemoteTmuxSession],
        into tabManager: TabManager
    ) -> [UUID] {
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

    func existingMirrorManager(for host: RemoteTmuxHost) -> TabManager? {
        for mirror in sessionMirrors.values where mirror.host.connectionHash == host.connectionHash {
            guard let workspaceId = mirror.mirroredWorkspaceId,
                  let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { continue }
            return manager
        }
        return nil
    }

    private func selectFirstMirrorWorkspace(for host: RemoteTmuxHost, in tabManager: TabManager) {
        let hostWorkspaceIds = Set(sessionMirrors.values.compactMap { mirror -> UUID? in
            guard mirror.host.connectionHash == host.connectionHash else { return nil }
            return mirror.mirroredWorkspaceId
        })
        guard let workspace = tabManager.tabs.first(where: { hostWorkspaceIds.contains($0.id) }) else { return }
        tabManager.selectWorkspace(workspace)
    }

    private static var unresolvedMirrorWindowId: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }
}
