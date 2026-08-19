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
        if focus {
            noteKeyboardFocusIntent(window: NSApp.keyWindow ?? NSApp.mainWindow)
        }
        guard let anchorIndex = tabs.firstIndex(where: {
            $0.id == anchorTabId
        }),
        let duplicatedPanelId = newSurface(
            kind: .browser,
            inPane: paneId,
            url: browser.currentURLForTabDuplication,
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
                window: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }
        return duplicatedPanel
    }
}
