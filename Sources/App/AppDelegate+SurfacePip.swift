import AppKit

extension AppDelegate {
    private enum SurfacePipAssociatedStorage {
        static var controllerKey = 0
    }

    var surfacePipController: SurfacePipController {
        if let controller = objc_getAssociatedObject(self, &SurfacePipAssociatedStorage.controllerKey) as? SurfacePipController {
            return controller
        }
        let controller = SurfacePipController(appDelegate: self)
        objc_setAssociatedObject(self, &SurfacePipAssociatedStorage.controllerKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }

    enum SurfacePipAction: String {
        case pop
        case `return`
        case toggle
    }

    enum SurfacePipActionError: Error, Equatable {
        case surfaceNotFound
        case unsupportedSurfaceType
        case notInPictureInPicture
        case actionFailed
    }

    struct SurfacePipActionState: Equatable {
        let panelId: UUID
        let isInPictureInPicture: Bool
    }

    func canPopOutSurfacePip(panelId: UUID) -> Bool {
        guard let source = workspaceContainingPanel(panelId: panelId),
              let panel = source.workspace.panels[panelId] else {
            return false
        }
        return surfacePipController.canPopOut(panel: panel)
    }

    func isSurfaceInPip(panelId: UUID) -> Bool {
        surfacePipController.isInPip(panelId: panelId)
    }

    func hasActiveSurfacePipPanels() -> Bool {
        surfacePipController.hasActivePanels
    }

    @discardableResult
    func toggleSurfacePipForCurrentContext() -> Bool {
        surfacePipController.toggleForCurrentContext()
    }

    @discardableResult
    func popOutSurfacePip(panelId: UUID) -> Bool {
        guard let source = workspaceContainingPanel(panelId: panelId) else { return false }
        return surfacePipController.popOut(panelId: panelId, from: source.workspace)
    }

    @discardableResult
    func returnSurfacePip(panelId: UUID) -> Bool {
        surfacePipController.returnSurface(panelId: panelId)
    }

    func performSurfacePipAction(
        panelId: UUID?,
        action: SurfacePipAction
    ) -> Result<SurfacePipActionState, SurfacePipActionError> {
        switch action {
        case .pop:
            let resolvedPanelId = panelId
                ?? surfacePipController.panelId(for: NSApp.keyWindow)
                ?? tabManager?.selectedWorkspace?.focusedPanelId
            guard let resolvedPanelId else { return .failure(.surfaceNotFound) }
            guard !surfacePipController.isInPip(panelId: resolvedPanelId) else {
                return .success(SurfacePipActionState(panelId: resolvedPanelId, isInPictureInPicture: true))
            }
            guard let source = workspaceContainingPanel(panelId: resolvedPanelId),
                  let panel = source.workspace.panels[resolvedPanelId] else {
                return .failure(.surfaceNotFound)
            }
            guard surfacePipController.canPopOut(panel: panel) else {
                return .failure(.unsupportedSurfaceType)
            }
            guard surfacePipController.popOut(panelId: resolvedPanelId, from: source.workspace) else {
                return .failure(.actionFailed)
            }
            return .success(SurfacePipActionState(panelId: resolvedPanelId, isInPictureInPicture: true))
        case .return:
            let resolvedPanelId = panelId
                ?? surfacePipController.panelId(for: NSApp.keyWindow)
                ?? surfacePipController.mostRecentActivePanelId
            guard let resolvedPanelId else { return .failure(.surfaceNotFound) }
            guard surfacePipController.isInPip(panelId: resolvedPanelId) else {
                return .failure(.notInPictureInPicture)
            }
            guard surfacePipController.returnSurface(panelId: resolvedPanelId) else {
                return .failure(.actionFailed)
            }
            return .success(SurfacePipActionState(panelId: resolvedPanelId, isInPictureInPicture: false))
        case .toggle:
            let resolvedPanelId = panelId
                ?? surfacePipController.panelId(for: NSApp.keyWindow)
                ?? surfacePipController.mostRecentActivePanelId
                ?? tabManager?.selectedWorkspace?.focusedPanelId
            guard let resolvedPanelId else { return .failure(.surfaceNotFound) }
            if surfacePipController.isInPip(panelId: resolvedPanelId) {
                guard surfacePipController.returnSurface(panelId: resolvedPanelId) else {
                    return .failure(.actionFailed)
                }
                return .success(SurfacePipActionState(panelId: resolvedPanelId, isInPictureInPicture: false))
            }
            guard let source = workspaceContainingPanel(panelId: resolvedPanelId),
                  let panel = source.workspace.panels[resolvedPanelId] else {
                return .failure(.surfaceNotFound)
            }
            guard surfacePipController.canPopOut(panel: panel) else {
                return .failure(.unsupportedSurfaceType)
            }
            guard surfacePipController.popOut(panelId: resolvedPanelId, from: source.workspace) else {
                return .failure(.actionFailed)
            }
            return .success(SurfacePipActionState(panelId: resolvedPanelId, isInPictureInPicture: true))
        }
    }

    func surfacePipPanelIdForKeyWindow() -> UUID? {
        surfacePipController.panelId(for: NSApp.keyWindow)
    }

    func sessionPipSurfaceSnapshots(includeScrollback: Bool) -> [SessionPipSurfaceSnapshot] {
        surfacePipController.snapshotsForSessionCapture().compactMap { entry in
            guard let panelSnapshot = sessionPanelSnapshot(forPipDetachedSurface: entry.detached, includeScrollback: includeScrollback) else {
                return nil
            }
            return SessionPipSurfaceSnapshot(
                panel: panelSnapshot,
                frame: SessionRectSnapshot(entry.frame),
                homeWorkspaceId: entry.homeWorkspaceId
            )
        }
    }

    private func sessionPanelSnapshot(
        forPipDetachedSurface detached: Workspace.DetachedSurfaceTransfer,
        includeScrollback: Bool
    ) -> SessionPanelSnapshot? {
        let panel = detached.panel
        let terminalSnapshot: SessionTerminalPanelSnapshot?
        let browserSnapshot: SessionBrowserPanelSnapshot?
        switch panel.panelType {
        case .terminal:
            guard let terminalPanel = panel as? TerminalPanel else { return nil }
            let scrollback = includeScrollback
                ? TerminalController.shared.readTerminalTextForSnapshot(
                    terminalPanel: terminalPanel,
                    includeScrollback: true,
                    lineLimit: SessionPersistencePolicy.maxScrollbackLinesPerTerminal
                )
                : nil
            terminalSnapshot = SessionTerminalPanelSnapshot(
                workingDirectory: detached.directory,
                scrollback: SessionPersistencePolicy.truncatedScrollback(scrollback),
                agent: detached.restorableAgent,
                tmuxStartCommand: nil,
                hibernation: nil,
                resumeBinding: detached.resumeBinding,
                textBoxDraft: terminalPanel.sessionTextBoxDraftSnapshot(),
                isRemoteTerminal: detached.isRemoteTerminal,
                remotePTYSessionID: detached.remotePTYSessionID,
                wasAgentRunning: nil
            )
            browserSnapshot = nil
        case .browser:
            guard let browserPanel = panel as? BrowserPanel,
                  browserPanel.shouldPersistSessionSnapshot() else {
                return nil
            }
            let historySnapshot = browserPanel.sessionNavigationHistorySnapshot()
            let diffViewerComponents = browserPanel.diffViewerSessionComponents()
            terminalSnapshot = nil
            browserSnapshot = SessionBrowserPanelSnapshot(
                urlString: browserPanel.preferredURLStringForSessionSnapshot(),
                profileID: browserPanel.profileID,
                shouldRenderWebView: browserPanel.shouldRenderWebViewForSessionSnapshot(),
                pageZoom: Double(browserPanel.currentPageZoomFactor()),
                developerToolsVisible: browserPanel.isDeveloperToolsVisible(),
                isMuted: browserPanel.isMuted,
                omnibarVisible: browserPanel.isOmnibarVisible,
                backHistoryURLStrings: historySnapshot.backHistoryURLStrings,
                forwardHistoryURLStrings: historySnapshot.forwardHistoryURLStrings,
                transparentBackground: browserPanel.sessionSnapshotTransparentBackground,
                diffViewerToken: diffViewerComponents?.token,
                diffViewerRequestPath: diffViewerComponents?.requestPath
            )
        case .markdown, .filePreview, .rightSidebarTool, .customSidebar, .agentSession,
             .project, .extensionBrowser, .workspaceTodo, .cloudVMLoading:
            return nil
        }

        return SessionPanelSnapshot(
            id: detached.panelId,
            stableSurfaceId: panel.stableSurfaceId,
            type: panel.panelType,
            title: detached.title,
            customTitle: detached.customTitle,
            customTitleSource: detached.customTitleSource,
            directory: detached.directory,
            directoryIsTrustedRemoteReport: detached.directoryIsTrustedRemoteReport,
            directoryRequiresRemoteTrust: nil,
            isPinned: detached.isPinned,
            isManuallyUnread: detached.manuallyUnread,
            hasUnreadIndicator: detached.restoredUnreadIndicator != nil,
            restoredUnreadContributesToWorkspace: detached.restoredUnreadIndicator?.contributesToWorkspaceUnread,
            notifications: nil,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: detached.ttyName,
            terminal: terminalSnapshot,
            browser: browserSnapshot,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil,
            customSidebar: nil,
            agentSession: nil,
            project: nil,
            workspaceTodo: nil
        )
    }
}
