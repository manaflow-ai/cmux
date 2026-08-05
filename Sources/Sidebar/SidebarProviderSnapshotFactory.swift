import AppKit
import CmuxNotifications
import CmuxPanes
import CmuxSidebar
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxSwiftRender
import Foundation

/// Projects the live window model into the immutable values consumed by every
/// non-default sidebar renderer. Keeping the projection outside the view
/// controller gives the AppKit, extension-XPC, and interpreted-sidebar lanes
/// one source of truth.
@MainActor
struct SidebarProviderSnapshotFactory {
    let tabManager: TabManager
    let sidebarUnread: SidebarUnreadModel
    let windowID: UUID

    func providerSnapshot() -> CmuxSidebarProviderSnapshot {
        let unreadSnapshot = sidebarUnread.snapshot
        return CmuxSidebarProviderSnapshot(
            sequence: UInt64(max(0, CmuxEventBus.shared.latestSequence)),
            selectedWorkspaceId: tabManager.selectedTabId,
            workspaces: tabManager.tabs.map {
                providerWorkspace($0, unreadSnapshot: unreadSnapshot)
            },
            windowId: windowID
        )
    }

    func extensionSnapshot() -> CmuxSidebarSnapshot {
        let snapshot = providerSnapshot()
        return CmuxSidebarSnapshot(
            sequence: snapshot.sequence,
            windowID: snapshot.windowId,
            selectedWorkspaceID: snapshot.selectedWorkspaceId,
            workspaces: snapshot.workspaces.map { workspace in
                CmuxSidebarWorkspace(
                    id: workspace.id,
                    title: workspace.title,
                    detail: workspace.customDescription,
                    isPinned: workspace.isPinned,
                    rootPath: workspace.rootPath,
                    projectRootPath: workspace.projectRootPath,
                    gitBranch: workspace.branchSummary,
                    unreadCount: workspace.unreadCount,
                    latestNotification: workspace.latestNotificationText,
                    listeningPorts: workspace.listeningPorts,
                    pullRequestURLs: workspace.pullRequestURLs,
                    surfaces: extensionSurfaces(for: workspace.id)
                )
            }
        )
    }

    func customDataContext(now: Date) -> [String: SwiftValue] {
        let selectedID = tabManager.selectedTabId
        let unreadSnapshot = sidebarUnread.snapshot
        let workspaces = tabManager.tabs.enumerated().map { index, workspace in
            workspace.customSidebarWorkspaceSnapshot(
                index: index,
                selectedId: selectedID,
                unreadCount: unreadSnapshot.unreadCount(forWorkspaceId: workspace.id)
            )
        }
        let selectedWorkspace = tabManager.tabs.first { $0.id == selectedID }
        return CustomSidebarDataContextBuilder().dataContext(
            for: CustomSidebarContextSnapshot(
                workspaces: workspaces,
                selectedWorkspaceId: selectedID,
                selectedWorkspaceTitle: selectedWorkspace?.customTitle
                    ?? selectedWorkspace?.title
                    ?? "",
                totalUnreadCount: unreadSnapshot.totalUnreadCount,
                now: now
            )
        )
    }

    private func providerWorkspace(
        _ workspace: Workspace,
        unreadSnapshot: SidebarUnreadSnapshot
    ) -> CmuxSidebarProviderWorkspace {
        CmuxSidebarProviderWorkspace(
            id: workspace.id,
            title: workspace.title,
            customDescription: workspace.customDescription,
            isPinned: workspace.isPinned,
            rootPath: workspace.presentedCurrentDirectory?.nilIfEmpty,
            projectRootPath: workspace.extensionSidebarProjectRootPath,
            branchSummary: workspace.sidebarGitBranchesInDisplayOrder().first?.branch,
            remoteDisplayTarget: workspace.remoteDisplayTarget,
            remoteConnectionState: workspace.remoteConnectionState.rawValue,
            unreadCount: unreadSnapshot.unreadCount(forWorkspaceId: workspace.id),
            latestNotificationText: unreadSnapshot.latestNotificationText(forWorkspaceId: workspace.id),
            latestSubmittedMessage: workspace.latestSubmittedMessage,
            latestSubmittedAt: workspace.latestSubmittedAt,
            listeningPorts: workspace.listeningPorts,
            pullRequestURLs: workspace.sidebarPullRequestsInDisplayOrder().map { $0.url.absoluteString },
            panelDirectories: workspace.sidebarFilesystemDirectoriesInDisplayOrder(),
            gitBranches: workspace.sidebarGitBranchesInDisplayOrder().map {
                CmuxSidebarProviderGitBranch(branch: $0.branch, isDirty: $0.isDirty)
            }
        )
    }

    private func extensionSurfaces(for workspaceID: UUID) -> [CmuxSidebarSurface] {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return []
        }
        return workspace.sidebarOrderedPanelIds().compactMap { panelID in
            guard let panel = workspace.panels[panelID] else { return nil }
            return CmuxSidebarSurface(
                id: panelID,
                title: workspace.panelTitle(panelId: panelID) ?? panel.displayTitle,
                kind: extensionSurfaceKind(for: panel.panelType),
                isFocused: workspace.focusedPanelId == panelID,
                isPinned: workspace.isPanelPinned(panelID),
                unreadCount: workspace.manualUnreadPanelIds.contains(panelID) ? 1 : 0,
                workingDirectory: workspace.reportedPanelDirectory(panelId: panelID)
            )
        }
    }

    private func extensionSurfaceKind(for panelType: PanelType) -> CmuxSidebarSurfaceKind {
        switch panelType {
        case .terminal:
            return .terminal
        case .browser:
            return .browser
        case .markdown:
            return .markdown
        case .filePreview:
            return .filePreview
        case .rightSidebarTool:
            return .rightSidebarTool
        case .agentSession:
            return .agentSession
        case .project:
            return .project
        case .customSidebar, .simulator, .extensionBrowser, .workspaceTodo, .cloudVMLoading,
             .mobilePairing, .accountSignIn:
            return .unknown
        }
    }
}

/// Routes extension-host mutations through the same `TabManager` entrypoints
/// used by menus, shortcuts, and the CLI.
@MainActor
struct SidebarExtensionActionRouter {
    let tabManager: TabManager

    func handle(_ action: CmuxSidebarAction) -> CmuxSidebarActionResult {
        switch action {
        case .createWorkspace(let title, let workingDirectory, let select):
            let workspace = tabManager.addWorkspace(
                title: title,
                workingDirectory: workingDirectory,
                inheritWorkingDirectory: workingDirectory == nil,
                select: select
            )
            return CmuxSidebarActionResult(accepted: true, message: workspace.id.uuidString)

        case .selectWorkspace(let workspaceID):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
                return .rejected(workspaceNotFound)
            }
            tabManager.selectWorkspace(workspace)
            return .accepted

        case .closeWorkspace(let workspaceID):
            guard tabManager.closeWorkspaceWithConfirmation(tabId: workspaceID) else {
                return .rejected(String(
                    localized: "sidebar.extensions.action.closeRejected",
                    defaultValue: "Workspace could not be closed"
                ))
            }
            return .accepted

        case .selectNextWorkspace:
            tabManager.selectNextTab()
            return .accepted

        case .selectPreviousWorkspace:
            tabManager.selectPreviousTab()
            return .accepted

        case .createTerminalSurface(let workspaceID):
            guard let workspace = workspace(
                identifiedBy: workspaceID,
                fallingBackTo: tabManager.selectedWorkspace
            ) else {
                return .rejected(workspaceNotFound)
            }
            selectIfNeeded(workspace)
            let panel = workspace.newTerminalSurfaceInFocusedPane(focus: true, initialInput: nil)
            if panel == nil, workspace.isRemoteTmuxMirror {
                return CmuxSidebarActionResult(
                    accepted: true,
                    message: String(
                        localized: "sidebar.extensions.action.remoteTmuxWindowRequested",
                        defaultValue: "Remote tmux window requested"
                    )
                )
            }
            return panel.map { CmuxSidebarActionResult(accepted: true, message: $0.id.uuidString) }
                ?? .rejected(surfaceCreateRejected)

        case .createBrowserSurface(let workspaceID, let urlString):
            let validatedURL = optionalHTTPURL(from: urlString)
            guard validatedURL.accepted else { return .rejected(urlRejected) }
            guard let workspace = workspace(
                identifiedBy: workspaceID,
                fallingBackTo: tabManager.selectedWorkspace
            ) else {
                return .rejected(workspaceNotFound)
            }
            selectIfNeeded(workspace)
            return tabManager.createBrowserSplit(direction: .right, url: validatedURL.url)
                .map { CmuxSidebarActionResult(accepted: true, message: $0.uuidString) }
                ?? .rejected(surfaceCreateRejected)

        case .selectSurface(let workspaceID, let surfaceID):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }),
                  workspace.panels[surfaceID] != nil else {
                return .rejected(surfaceNotFound)
            }
            tabManager.selectWorkspace(workspace)
            workspace.focusPanel(surfaceID)
            return .accepted

        case .selectNextSurface:
            tabManager.selectNextSurface()
            return .accepted

        case .selectPreviousSurface:
            tabManager.selectPreviousSurface()
            return .accepted

        case .closeSurface(let workspaceID, let surfaceID):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
                return .rejected(workspaceNotFound)
            }
            guard workspace.panels[surfaceID] != nil else { return .rejected(surfaceNotFound) }
            tabManager.closePanelWithConfirmation(tabId: workspaceID, surfaceId: surfaceID)
            return .accepted

        case .splitTerminal(let workspaceID, let surfaceID, let direction):
            guard let direction = splitDirection(from: direction),
                  let panelID = tabManager.createSplit(
                    tabId: workspaceID,
                    surfaceId: surfaceID,
                    direction: direction
                  ) else {
                return .rejected(surfaceCreateRejected)
            }
            return CmuxSidebarActionResult(accepted: true, message: panelID.uuidString)

        case .splitBrowser(let workspaceID, let surfaceID, let direction, let urlString):
            let validatedURL = optionalHTTPURL(from: urlString)
            guard validatedURL.accepted,
                  let direction = splitDirection(from: direction),
                  let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }),
                  workspace.panels[surfaceID] != nil else {
                return .rejected(surfaceCreateRejected)
            }
            tabManager.selectWorkspace(workspace)
            workspace.focusPanel(surfaceID)
            return tabManager.createBrowserSplit(direction: direction, url: validatedURL.url)
                .map { CmuxSidebarActionResult(accepted: true, message: $0.uuidString) }
                ?? .rejected(surfaceCreateRejected)

        case .toggleSurfaceZoom(let workspaceID, let surfaceID):
            guard tabManager.toggleSplitZoom(tabId: workspaceID, surfaceId: surfaceID) else {
                return .rejected(surfaceNotFound)
            }
            return .accepted

        case .openURL(let urlString):
            guard let url = requiredHTTPURL(from: urlString), NSWorkspace.shared.open(url) else {
                return .rejected(urlRejected)
            }
            return .accepted
        }
    }

    private func workspace(
        identifiedBy workspaceID: UUID?,
        fallingBackTo fallback: Workspace?
    ) -> Workspace? {
        workspaceID.flatMap { id in tabManager.tabs.first(where: { $0.id == id }) } ?? fallback
    }

    private func selectIfNeeded(_ workspace: Workspace) {
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
    }

    private func optionalHTTPURL(from value: String?) -> (url: URL?, accepted: Bool) {
        guard let value, !value.isEmpty else { return (nil, true) }
        guard let url = requiredHTTPURL(from: value) else { return (nil, false) }
        return (url, true)
    }

    private func requiredHTTPURL(from value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private func splitDirection(from direction: CmuxSidebarSplitDirection) -> SplitDirection? {
        switch direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
    }

    private var workspaceNotFound: String {
        String(
            localized: "sidebar.extensions.action.workspaceNotFound",
            defaultValue: "Workspace not found"
        )
    }

    private var surfaceNotFound: String {
        String(
            localized: "sidebar.extensions.action.surfaceNotFound",
            defaultValue: "Surface not found"
        )
    }

    private var surfaceCreateRejected: String {
        String(
            localized: "sidebar.extensions.action.surfaceCreateRejected",
            defaultValue: "Surface could not be created"
        )
    }

    private var urlRejected: String {
        String(
            localized: "sidebar.extensions.action.urlRejected",
            defaultValue: "URL could not be opened"
        )
    }
}
