import CmuxMobileShellModel
import CmuxMobileTerminal
import CmuxMobileWorkspace
import SwiftUI

extension WorkspaceShellView {
    /// Count of workspaces with unread activity, excluding the open workspace.
    func unreadWorkspaceCount(excluding workspaceID: MobileWorkspacePreview.ID?) -> Int {
        store.workspaces.filter { $0.hasUnread && $0.id != workspaceID }.count
    }

    /// Pops one compact navigation level.
    func popCompactStack() {
        guard !compactNavigationPath.isEmpty else { return }
        compactNavigationPath.removeLast()
    }

    func reconcileCompactPath(with visibleWorkspaceIDs: Set<MobileWorkspacePreview.ID>) {
        guard let routedWorkspaceID = compactNavigationPath.last?.workspaceID,
              !visibleWorkspaceIDs.contains(routedWorkspaceID),
              store.selectedWorkspaceID != routedWorkspaceID else { return }
        if let selectedWorkspaceID = store.selectedWorkspaceID,
           visibleWorkspaceIDs.contains(selectedWorkspaceID) {
            compactNavigationPath = [.hub(workspaceID: selectedWorkspaceID)]
        } else {
            compactNavigationPath.removeAll { !visibleWorkspaceIDs.contains($0.workspaceID) }
        }
    }

    @ViewBuilder
    func compactDestination(for route: WorkspaceShellRoute) -> some View {
        switch route {
        case .hub(let workspaceID):
            workspaceHubDestination(
                for: workspaceID,
                backButtonConfiguration: WorkspaceBackButtonConfiguration(
                    unreadCount: unreadWorkspaceCount(excluding: workspaceID),
                    badgeContrast: .darkBackground,
                    action: popCompactStack
                )
            )
            .background(InteractiveSwipeBackEnabler())
        case .pane(let workspaceID, let paneID, let surfaceID):
            paneDestination(
                for: workspaceID,
                paneID: paneID,
                initialSurfaceID: surfaceID,
                createWorkspace: createWorkspaceInCompactStack
            )
            .navigationTransition(.zoom(sourceID: paneID, in: paneTransitionNamespace))
            .background(InteractiveSwipeBackEnabler())
        }
    }

    @ViewBuilder
    func splitDestination(for route: WorkspaceShellRoute) -> some View {
        switch route {
        case .hub(let workspaceID):
            workspaceHubDestination(for: workspaceID, backButtonConfiguration: nil)
        case .pane(let workspaceID, let paneID, let surfaceID):
            paneDestination(
                for: workspaceID,
                paneID: paneID,
                initialSurfaceID: surfaceID,
                createWorkspace: createWorkspaceIfConnected,
                safeAreaContext: splitColumnVisibility == .detailOnly ? .fullWidth : .splitSidebarVisible
            )
        }
    }

    @ViewBuilder
    func workspaceHubDestination(
        for workspaceID: MobileWorkspacePreview.ID?,
        backButtonConfiguration: WorkspaceBackButtonConfiguration?
    ) -> some View {
        WorkspaceHubContainer(
            store: store,
            workspaceID: workspaceID,
            backButtonConfiguration: backButtonConfiguration,
            transitionNamespace: paneTransitionNamespace,
            selectPane: openPane,
            signOut: signOut
        )
    }

    func openPane(_ pane: WorkspaceHubPaneSnapshot) {
        guard let workspaceID = store.selectedWorkspaceID,
              let surfaceID = pane.activeSurfaceID else { return }
        if pane.activeKind == .terminal {
            store.selectTerminalFromChrome(MobileTerminalPreview.ID(rawValue: surfaceID))
        }
        let route = WorkspaceShellRoute.pane(
            workspaceID: workspaceID,
            paneID: pane.id,
            surfaceID: surfaceID
        )
        if usesCompactStack {
            if compactNavigationPath.last?.workspaceID != workspaceID {
                compactNavigationPath = [.hub(workspaceID: workspaceID)]
            }
            compactNavigationPath.append(route)
        } else {
            splitDetailPath = [route]
        }
    }

    @ViewBuilder
    func paneDestination(
        for workspaceID: MobileWorkspacePreview.ID?,
        paneID: String,
        initialSurfaceID: String,
        createWorkspace: @escaping () -> Void,
        safeAreaContext: MobileTerminalSafeAreaContext = .fullWidth
    ) -> some View {
        WorkspaceDetailContainer(
            store: store,
            workspaceID: workspaceID,
            paneID: paneID,
            initialSurfaceID: initialSurfaceID,
            createWorkspace: createWorkspace,
            canCreateWorkspace: canCreateWorkspaceForMacSelection,
            renameWorkspace: renameWorkspaceClosure,
            setWorkspaceUnread: setWorkspaceUnreadClosure,
            closeWorkspace: closeWorkspaceClosure,
            safeAreaContext: safeAreaContext,
            backButtonConfiguration: nil,
            signOut: signOut
        )
    }
}
