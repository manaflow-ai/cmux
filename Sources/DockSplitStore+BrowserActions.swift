import AppKit
import Bonsplit
import Foundation

extension DockSplitStore {
    /// Duplicates a Dock browser beside its source while preserving browser state.
    @discardableResult
    func duplicateBrowserToRight(
        panelId: UUID,
        focus: Bool = true
    ) -> BrowserPanel? {
        guard let anchorTabId = surfaceId(forPanelId: panelId),
              let paneId = paneId(forPanelId: panelId),
              let browser = browserPanel(for: panelId) else {
            return nil
        }
        let tabs = bonsplitController.tabs(inPane: paneId)
        let catalog = SurfaceCatalog.shared
        let keepsCloudRoute = browser.retainsCloudResourceForDuplication
        let record = keepsCloudRoute
            ? catalog.projectionRecord(forPanel: panelId).flatMap { $0.resource.machine.isLocal ? nil : $0 }
            : nil
        let resource = keepsCloudRoute ? (record?.resource ?? browser.cloudResourceForDuplication) : nil
        let isCloud = resource?.machine.isLocal == false
        guard surfaceOwnershipPolicy.rejection(for: machineOwningSurface(panelId)) == nil else { return nil }
        guard let anchorIndex = tabs.firstIndex(where: {
            $0.id == anchorTabId
        }),
        let duplicatedPanelId = newSurface(
            kind: .browser,
            inPane: paneId,
            url: isCloud ? nil : browser.currentURLForTabDuplication,
            focus: false,
            preferredProfileID: browser.profileID,
            chromeVisibility: browser.chromeVisibility,
            bypassRemoteProxy:
                browser.bypassesRemoteWorkspaceProxyForTabDuplication,
            websiteDataStore:
                browser.explicitEphemeralWebsiteDataStoreForSibling
        ),
        let duplicatedPanel = browserPanel(for: duplicatedPanelId),
        let duplicatedTabId = surfaceId(forPanelId: duplicatedPanelId) else {
            return nil
        }

        let focusWindow = NSApp.keyWindow ?? NSApp.mainWindow
        if let resource, isCloud {
            duplicatedPanel.retainTransferredSurfaceMachine(resource.machine)
            catalog.restore([SurfaceProjectionRecord(panelID: duplicatedPanel.id, resource: resource,
                remoteWorkspaceID: record?.remoteWorkspaceID)], workspaceID: workspaceId)
            duplicatedPanel.restoreCloudResource(resource, preferredURL: browser.currentURLForTabDuplication)
        }
        if focus {
            noteKeyboardFocusIntent(window: focusWindow)
        }

        duplicatedPanel.setMuted(browser.isMuted)
        bonsplitController.updateTab(
            duplicatedTabId,
            isAudioMuted: duplicatedPanel.isMuted
        )
        let desiredIndex = anchorIndex + 1
        let updatedTabs = bonsplitController.tabs(inPane: paneId)
        if updatedTabs.firstIndex(where: { $0.id == duplicatedTabId })
            != desiredIndex {
            _ = bonsplitController.reorderTab(
                duplicatedTabId,
                toIndex: desiredIndex
            )
        }
        if focus {
            focusPanelFromDockInteraction(
                duplicatedPanelId,
                window: focusWindow
            )
        }
        return duplicatedPanel
    }
}
