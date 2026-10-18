import Bonsplit
import CmuxWorkspaces
import Foundation

/// Workspace surface creation for the CodeRouter guide opened from the Cloud sidebar.
extension Workspace {
    @discardableResult
    func newCoderouterGuideSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> CoderouterGuidePanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        let guidePanel = CoderouterGuidePanel()
        panels[guidePanel.id] = guidePanel
        panelTitles[guidePanel.id] = guidePanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: guidePanel.displayTitle,
            icon: guidePanel.displayIcon,
            kind: SurfaceKind.coderouterGuide.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: guidePanel.id)
            panelTitles.removeValue(forKey: guidePanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: guidePanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            guidePanel.id,
            paneId: paneId,
            kind: SurfaceKind.coderouterGuide.rawValue,
            origin: "coderouter_guide_tab",
            focused: shouldFocusNewTab
        )
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: guidePanel.id,
                previousHostedView: previousHostedView
            )
        }

        return guidePanel
    }

    /// Focuses the existing guide pane or creates one in the requested pane.
    @discardableResult
    func openOrFocusCoderouterGuideSurface(
        inPane paneId: PaneID,
        focus: Bool = true
    ) -> CoderouterGuidePanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        for (existingId, panel) in panels {
            guard panel is CoderouterGuidePanel else { continue }
            if focus {
                focusPanel(existingId)
            }
            return panel as? CoderouterGuidePanel
        }
        return newCoderouterGuideSurface(inPane: paneId, focus: focus)
    }
}
