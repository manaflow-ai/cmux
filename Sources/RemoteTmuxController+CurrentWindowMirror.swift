import Foundation

extension RemoteTmuxController {
    /// Mirrors every tmux session on `host` into the current main window.
    @discardableResult
    func mirrorHostInCurrentWindow(
        host: RemoteTmuxHost,
        activateWindow: Bool = true
    ) async throws -> RemoteTmuxAttachOutcome {
        guard let appDelegate = AppDelegate.shared else {
            throw RemoteTmuxError.unreachable("app not ready")
        }
        if let existing = try currentWindowMirrorOutcome(
            host: host,
            activateWindow: activateWindow,
            appDelegate: appDelegate
        ) {
            return existing
        }

        return try await withMirrorAttachGuard(host: host) {
            let preflight = try await prepareMirrorAttach(host: host, createIfEmpty: false) { _ in
                try currentWindowMirrorOutcome(
                    host: host,
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

            let manager: TabManager
            if let current = appDelegate.tabManager {
                manager = current
            } else {
                let windowId = appDelegate.createMainWindow(shouldActivate: activateWindow)
                guard let created = appDelegate.tabManagerFor(windowId: windowId) else {
                    throw RemoteTmuxError.unreachable("could not create window")
                }
                manager = created
            }

            var firstMirroredWorkspaceId: UUID?
            for session in sessions {
                do {
                    try mirrorSession(host: host, sessionName: session.name, into: manager)
                    if firstMirroredWorkspaceId == nil {
                        let key = Self.connectionKey(host: host, sessionName: session.name)
                        firstMirroredWorkspaceId = sessionMirrors[key]?.mirroredWorkspaceId
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
