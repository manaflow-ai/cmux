import Foundation

extension RemoteTmuxController {
    /// Mirrors every tmux session on `host` into the current main window.
    @discardableResult
    func mirrorHostInCurrentWindow(
        host: RemoteTmuxHost,
        activateWindow: Bool = true,
        targetWindowId: UUID? = nil
    ) async throws -> RemoteTmuxAttachOutcome {
        guard let appDelegate = AppDelegate.shared else {
            throw RemoteTmuxError.unreachable("app not ready")
        }
        if !hostHasConnectedMirror(host),
           let existing = try currentWindowMirrorOutcome(
               host: host,
               activateWindow: activateWindow,
               appDelegate: appDelegate
           ) {
            return existing
        }
        let capturedTargetManager = targetWindowId.flatMap {
            appDelegate.tabManagerFor(windowId: $0)
        } ?? appDelegate.tabManager

        return try await withMirrorAttachGuard(host: host) {
            let preflight = try await prepareMirrorAttach(host: host, createIfEmpty: false) { discoveredSessions in
                try completeCurrentWindowMirrorOutcome(
                    host: host,
                    sessions: discoveredSessions,
                    activateWindow: activateWindow,
                    appDelegate: appDelegate
                )
            }
            let sessions: [RemoteTmuxSession]
            switch preflight {
            case .authRequired(let sshArgv):
                return .authRequired(sshArgv: sshArgv)
            case .mirrored(let windowId):
                return .mirrored(windowId: windowId)
            case .sessions(let preparedSessions):
                sessions = preparedSessions
            }

            var createdFallbackWindowId: UUID?
            let manager: TabManager
            if let existingMirrorManager = currentWindowMirrorManager(
                host: host,
                appDelegate: appDelegate
            ) {
                manager = existingMirrorManager
            } else if let capturedTargetManager,
               let capturedWindowId = appDelegate.windowId(for: capturedTargetManager),
               appDelegate.windowForMainWindowId(capturedWindowId) != nil {
                manager = capturedTargetManager
            } else if let current = appDelegate.tabManager {
                manager = current
            } else {
                let windowId = appDelegate.createMainWindow(shouldActivate: activateWindow)
                guard let created = appDelegate.tabManagerFor(windowId: windowId) else {
                    throw RemoteTmuxError.unreachable("could not create window")
                }
                createdFallbackWindowId = windowId
                manager = created
            }

            var firstMirroredWorkspaceId: UUID?
            for session in sessions {
                do {
                    try mirrorSession(host: host, sessionName: session.name, into: manager)
                    if firstMirroredWorkspaceId == nil {
                        let key = Self.connectionKey(host: host, sessionName: session.name)
                        let workspaceId = sessionMirrors[key]?.mirroredWorkspaceId
                        if workspaceId.map({ id in manager.tabs.contains(where: { $0.id == id }) }) == true {
                            firstMirroredWorkspaceId = workspaceId
                        }
                    }
                } catch {
                    #if DEBUG
                    cmuxDebugLog("remote-tmux: mirror session \(session.name) on \(host.destination) failed: \(error)")
                    #endif
                }
            }

            let mirroredWorkspaceIds = Set(manager.tabs.map(\.id))
            let hasMirrorForHost = sessionMirrors.values.contains { mirror in
                mirror.host.connectionHash == host.connectionHash
                    && mirror.mirroredWorkspaceId.map(mirroredWorkspaceIds.contains) == true
            }
            guard hasMirrorForHost else {
                if let createdFallbackWindowId {
                    appDelegate.discardMainWindowWithoutClosedHistory(windowId: createdFallbackWindowId)
                }
                closeControlMasterIfIdle(host: host)
                throw RemoteTmuxError.unreachable("could not mirror any tmux session on \(host.destination)")
            }
            guard let windowId = appDelegate.windowId(for: manager) else {
                throw RemoteTmuxError.unreachable("could not resolve window for \(host.destination) mirror")
            }
            if activateWindow, let firstMirroredWorkspaceId {
                manager.selectWorkspace(firstMirroredWorkspaceId)
                appDelegate.windowForMainWindowId(windowId)?.makeKeyAndOrderFront(nil)
            }
            return .mirrored(windowId: windowId)
        }
    }

    private func completeCurrentWindowMirrorOutcome(
        host: RemoteTmuxHost,
        sessions: [RemoteTmuxSession],
        activateWindow: Bool,
        appDelegate: AppDelegate
    ) throws -> RemoteTmuxAttachOutcome? {
        for session in sessions {
            let key = Self.connectionKey(host: host, sessionName: session.name)
            guard let workspaceId = sessionMirrors[key]?.mirroredWorkspaceId,
                  appDelegate.tabManagerFor(tabId: workspaceId) != nil else {
                return nil
            }
        }
        return try currentWindowMirrorOutcome(
            host: host,
            activateWindow: activateWindow,
            appDelegate: appDelegate
        )
    }

    private func hostHasConnectedMirror(_ host: RemoteTmuxHost) -> Bool {
        sessionMirrors.values.contains { mirror in
            mirror.host.connectionHash == host.connectionHash
                && mirror.connection.connectionState == .connected
        }
    }

    private func currentWindowMirrorManager(
        host: RemoteTmuxHost,
        appDelegate: AppDelegate
    ) -> TabManager? {
        for mirror in sessionMirrors.values where mirror.host.connectionHash == host.connectionHash {
            guard let workspaceId = mirror.mirroredWorkspaceId,
                  let manager = appDelegate.tabManagerFor(tabId: workspaceId),
                  let windowId = appDelegate.windowId(for: manager),
                  appDelegate.windowForMainWindowId(windowId) != nil else { continue }
            return manager
        }
        return nil
    }

    private func currentWindowMirrorOutcome(
        host: RemoteTmuxHost,
        activateWindow: Bool,
        appDelegate: AppDelegate
    ) throws -> RemoteTmuxAttachOutcome? {
        guard let workspaceId = sessionMirrors.values
            .first(where: { $0.host.connectionHash == host.connectionHash })?
            .mirroredWorkspaceId,
            let manager = appDelegate.tabManagerFor(tabId: workspaceId)
        else { return nil }
        guard let windowId = appDelegate.windowId(for: manager) else {
            throw RemoteTmuxError.unreachable("could not resolve window for existing \(host.destination) mirror")
        }
        if activateWindow {
            manager.selectWorkspace(workspaceId)
            appDelegate.windowForMainWindowId(windowId)?.makeKeyAndOrderFront(nil)
        }
        return .mirrored(windowId: windowId)
    }
}
