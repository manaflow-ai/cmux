import AppKit
import CmuxSocketControl
import Bonsplit
import Foundation
import UniformTypeIdentifiers


// MARK: - Navigation URL Handling
extension AppDelegate {
    @discardableResult
    func handleCmuxNavigationURLs(from urls: [URL]) -> Bool {
        var navigationRequests: [CmuxNavigationURLRequest] = []
        var parseErrors: [(url: URL, error: CmuxNavigationURLParseError)] = []

        for url in urls {
            switch CmuxNavigationURLRequest.parse(url) {
            case .success(.some(let request)):
                navigationRequests.append(request)
            case .success(nil):
                break
            case .failure(let error):
                parseErrors.append((url, error))
            }
        }

        let navigationIntentCount = navigationRequests.count + parseErrors.count
        guard navigationIntentCount > 0 else { return false }

        guard navigationIntentCount == 1 else {
#if DEBUG
            cmuxDebugLog("navigationURL.ignored reason=multipleLinks count=\(urls.count) intents=\(navigationIntentCount)")
#endif
            return true
        }

        if let parseError = parseErrors.first {
#if DEBUG
            cmuxDebugLog("navigationURL.blocked reason=\(parseError.error) url=\(parseError.url.absoluteString.prefix(160))")
#endif
            return true
        }

        if let request = navigationRequests.first {
            _ = handleCmuxNavigationURLRequest(request)
        }
        return true
    }

    @discardableResult
    private func handleCmuxNavigationURLRequest(_ request: CmuxNavigationURLRequest) -> Bool {
        let workspaceId: UUID
        switch request.target {
        case .workspace(let id), .pane(let id, _), .surface(let id, _):
            workspaceId = id
        }

        guard let context = mainWindowContexts.values.first(where: { context in
            context.tabManager.tabs.contains(where: { $0.id == workspaceId })
        }),
              let workspace = context.tabManager.tabs.first(where: { $0.id == workspaceId }),
              let window = context.window ?? windowForMainWindowId(context.windowId) else {
#if DEBUG
            cmuxDebugLog("navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8))")
#endif
            return false
        }

        let targetPanelId: UUID?
        switch request.target {
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
        case .surface(_, let surfaceId):
            guard workspace.panels[surfaceId] != nil,
                  workspace.surfaceIdFromPanelId(surfaceId) != nil else {
#if DEBUG
                cmuxDebugLog(
                    "navigationURL.notFound workspace=\(workspaceId.uuidString.prefix(8)) " +
                    "surface=\(surfaceId.uuidString.prefix(8))"
                )
#endif
                return false
            }
            targetPanelId = surfaceId
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

}
