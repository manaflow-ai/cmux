import Bonsplit
import Foundation

/// The page-zoom mutation requested for a Dock browser panel.
enum DockPanelZoomAction: Sendable {
    case increase
    case decrease
    case reset
}

extension DockSplitStore {
    /// Applies one page-zoom operation to a Dock browser without changing the
    /// Dock's selected panel. An explicit panel id is used by menu/context
    /// actions; omitting it targets the currently focused Dock browser.
    @discardableResult
    func performDockPanelZoom(
        _ action: DockPanelZoomAction,
        panelId: UUID? = nil
    ) -> Bool {
        guard let targetPanelId = panelId ?? focusedPanelId,
              let browser = browserPanel(for: targetPanelId) else {
            return false
        }
        switch action {
        case .increase:
            return browser.zoomIn()
        case .decrease:
            return browser.zoomOut()
        case .reset:
            return browser.resetZoom()
        }
    }

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
        guard let anchorIndex = tabs.firstIndex(where: {
            $0.id == anchorTabId
        }),
        let duplicatedPanelId = newSurface(
            kind: .browser,
            inPane: paneId,
            url: browser.currentURLForTabDuplication,
            focus: focus,
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
        return duplicatedPanel
    }
}
