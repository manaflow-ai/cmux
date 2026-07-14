import AppKit
import Foundation

extension GhosttyApp {
    /// Opens a terminal link in a neighboring cmux browser when available.
    @MainActor
    static func openEmbeddedBrowserLink(
        url: URL,
        sourceWorkspaceId: UUID,
        sourcePanelId: UUID,
        host: String
    ) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled() else {
            #if DEBUG
            cmuxDebugLog("link.openURL deferred embedded but cmuxBrowser=disabled, opening externally url=\(url)")
            #endif
            return NSWorkspace.shared.open(url)
        }

        guard let app = AppDelegate.shared,
              let resolved = app.workspaceContainingPanel(
                panelId: sourcePanelId,
                preferredWorkspaceId: sourceWorkspaceId
              ) else {
            #if DEBUG
            cmuxDebugLog(
                "link.openURL deferred embedded but workspace lookup failed, opening externally " +
                "tabId=\(sourceWorkspaceId) surfaceId=\(sourcePanelId) url=\(url)"
            )
            #endif
            return NSWorkspace.shared.open(url)
        }

        let workspace = resolved.workspace
        #if DEBUG
        if workspace.id != sourceWorkspaceId {
            cmuxDebugLog(
                "link.openURL workspace.remap sourceTab=\(sourceWorkspaceId) " +
                "resolvedTab=\(workspace.id) surfaceId=\(sourcePanelId)"
            )
        }
        #endif

        let openedInBrowser: Bool
        if let targetPane = workspace.preferredRightSideTargetPane(fromPanelId: sourcePanelId) {
            #if DEBUG
            cmuxDebugLog("link.openURL opening in existing browser pane=\(targetPane)")
            #endif
            openedInBrowser = workspace.newBrowserSurface(inPane: targetPane, url: url, focus: true) != nil
        } else {
            #if DEBUG
            cmuxDebugLog("link.openURL opening as new browser split from surface=\(sourcePanelId)")
            #endif
            openedInBrowser = workspace.newBrowserSplit(
                from: sourcePanelId,
                orientation: .horizontal,
                url: url
            ) != nil
        }

        guard openedInBrowser else {
            #if DEBUG
            cmuxDebugLog(
                "link.openURL deferred embedded browser creation failed, opening externally " +
                "host=\(host) url=\(url)"
            )
            #endif
            return NSWorkspace.shared.open(url)
        }
        return true
    }
}
