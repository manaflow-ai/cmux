import AppKit
import Foundation

extension AppDelegate {
    nonisolated static func shouldSaveSessionSnapshotOnRestoreCompletion(
        isManualReopen: Bool
    ) -> Bool {
        !isManualReopen
    }

    nonisolated static func shouldSkipSessionSaveDuringRestore(
        isApplyingSessionRestore: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isApplyingSessionRestore && !includeScrollback
    }

    @discardableResult
    func handleCmuxNavigationURLRequest(_ request: CmuxNavigationURLRequest) -> Bool {
        let lookup = cmuxNavigationWorkspaceLookup()
        let resolver = CmuxNavigationTargetResolver(workspaces: lookup.descriptors)
        guard let resolution = resolver.resolve(request.target) else {
            if shouldDeferNavigationURLRequestsForStartupRestore {
                pendingStartupNavigationURLRequests.append(request)
#if DEBUG
                cmuxDebugLog(
                    "navigationURL.deferred reason=startupRestorePending " +
                    "url=\(request.originalURL.absoluteString.prefix(120))"
                )
#endif
                return true
            }
#if DEBUG
            switch request.target {
            case .workspace(let workspaceId):
                cmuxDebugLog("navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8))")
            case .pane(let workspaceId, let paneId):
                cmuxDebugLog(
                    "navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8)) " +
                    "pane=\(paneId.uuidString.prefix(8))"
                )
            case .surface(let workspaceId, let surfaceId):
                cmuxDebugLog(
                    "navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8)) " +
                    "surface=\(surfaceId.uuidString.prefix(8))"
                )
            }
#endif
            return false
        }

        let workspaceId = resolution.workspaceId
        guard let context = lookup.contextByWorkspaceId[workspaceId],
              let workspace = context.tabManager.tabs.first(where: { $0.id == workspaceId }),
              let window = context.window ?? windowForMainWindowId(context.windowId) else {
            if shouldDeferNavigationURLRequestsForStartupRestore {
                pendingStartupNavigationURLRequests.append(request)
#if DEBUG
                cmuxDebugLog(
                    "navigationURL.deferred reason=windowPendingStartupRestore " +
                    "workspace=\(workspaceId.uuidString.prefix(8))"
                )
#endif
                return true
            }
#if DEBUG
            cmuxDebugLog("navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8))")
#endif
            return false
        }

        let targetPanelId: UUID?
        switch resolution {
        case .workspace:
            targetPanelId = nil
        case .pane(_, let paneId):
            guard let pane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == paneId }) else {
#if DEBUG
                cmuxDebugLog(
                    "navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8)) " +
                    "pane=\(paneId.uuidString.prefix(8))"
                )
#endif
                return false
            }
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: pane)
                ?? workspace.bonsplitController.tabs(inPane: pane).first
            targetPanelId = selectedTab.flatMap { workspace.panelIdFromSurfaceId($0.id) }
            if targetPanelId == nil {
                workspace.bonsplitController.focusPane(pane)
            }
        case .surface(_, let panelId):
            targetPanelId = panelId
        }

        prepareForExplicitOpenIntentAtStartup()
        setActiveMainWindow(window)
        _ = focusMainWindow(windowId: context.windowId)
        context.tabManager.focusTab(
            workspaceId,
            surfaceId: targetPanelId,
            suppressFlash: true
        )

#if DEBUG
        let surface = targetPanelId.map { String($0.uuidString.prefix(8)) } ?? "nil"
        cmuxDebugLog(
            "navigationURL.focus workspace=\(workspaceId.uuidString.prefix(8)) " +
            "surface=\(surface) window=\(context.windowId.uuidString.prefix(8))"
        )
#endif
        return true
    }

    private func cmuxNavigationWorkspaceLookup() -> (
        descriptors: [CmuxNavigationTargetResolver.WorkspaceDescriptor],
        contextByWorkspaceId: [UUID: MainWindowContext]
    ) {
        var descriptors: [CmuxNavigationTargetResolver.WorkspaceDescriptor] = []
        var contextByWorkspaceId: [UUID: MainWindowContext] = [:]
        for context in mainWindowContexts.values.sorted(by: { $0.windowId.uuidString < $1.windowId.uuidString }) {
            for workspace in context.tabManager.tabs {
                descriptors.append(workspace.cmuxNavigationDescriptor)
                contextByWorkspaceId[workspace.id] = context
            }
        }
        return (descriptors, contextByWorkspaceId)
    }

    func cmuxNavigationWorkspaceDescriptors() -> [CmuxNavigationTargetResolver.WorkspaceDescriptor] {
        cmuxNavigationWorkspaceLookup().descriptors
    }

    var shouldDeferNavigationURLRequestsForStartupRestore: Bool {
        !didAttemptStartupSessionRestore || isApplyingSessionRestore
    }

    func liveStableIdentitySet() -> Set<UUID> {
        var identities: Set<UUID> = []
        for context in mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                identities.insert(workspace.stableId)
                for panel in workspace.panels.values {
                    identities.insert(panel.stableSurfaceId)
                }
            }
        }
        return identities
    }

    func flushPendingStartupNavigationURLRequests() {
        guard !pendingStartupNavigationURLRequests.isEmpty else { return }
        let requests = pendingStartupNavigationURLRequests
        pendingStartupNavigationURLRequests.removeAll()
        for request in requests {
            _ = handleCmuxNavigationURLRequest(request)
        }
    }
}
