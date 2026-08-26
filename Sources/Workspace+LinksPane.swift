import Bonsplit
import CmuxBrowser
import CmuxWorkspaces
import Foundation

extension Workspace {
    @discardableResult
    func newWorkspaceLinksSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> LinksPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        let linksPanel = LinksPanel(
            workspace: self,
            titleFetcher: LinkTitleFetcher(
                pageMetadataFetcher: BrowserPageMetadataService()
            )
        )
        panels[linksPanel.id] = linksPanel
        panelTitles[linksPanel.id] = linksPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: linksPanel.displayTitle,
            icon: linksPanel.displayIcon,
            kind: SurfaceKind.links.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: linksPanel.id)
            panelTitles.removeValue(forKey: linksPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: linksPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            linksPanel.id,
            paneId: paneId,
            kind: SurfaceKind.links.rawValue,
            origin: "links_tab",
            focused: shouldFocusNewTab
        )
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: linksPanel.id,
                previousHostedView: previousHostedView
            )
        }

        return linksPanel
    }

    @discardableResult
    func openOrFocusWorkspaceLinksSurface(
        inPane paneId: PaneID,
        focus: Bool = true
    ) -> LinksPanel? {
        for (existingId, panel) in panels {
            guard let linksPanel = panel as? LinksPanel else { continue }
            if focus {
                focusPanel(existingId)
            }
            return linksPanel
        }
        return newWorkspaceLinksSurface(inPane: paneId, focus: focus)
    }

    func combineLinksStateIntoSessionAutosaveFingerprint(into hasher: inout Hasher) {
        hasher.combine(linksState.entries)
    }

    func restoreLinksState(from snapshot: SessionWorkspaceSnapshot) {
        linksState.restore(
            snapshot.restoredLinks,
            retentionLimit: LinksCaptureSettings().snapshot().retentionLimit
        )
    }
}
