import Bonsplit
import CmuxWorkspaces
import Foundation

extension Workspace {
    @discardableResult
    func openOrFocusIssueInboxSurface(focus: Bool = true) -> IssueInboxPanel? {
        guard let paneId = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first else {
            return nil
        }
        return openOrFocusIssueInboxSurface(inPane: paneId, focus: focus)
    }

    @discardableResult
    func openOrFocusIssueInboxSurface(
        inPane paneId: PaneID,
        focus: Bool = true
    ) -> IssueInboxPanel? {
        for (existingId, panel) in panels {
            guard let issueInboxPanel = panel as? IssueInboxPanel else { continue }
            if focus {
                focusPanel(existingId)
            }
            return issueInboxPanel
        }
        return newIssueInboxSurface(inPane: paneId, focus: focus)
    }

    @discardableResult
    func newIssueInboxSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> IssueInboxPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let issueInboxPanel = IssueInboxPanel(store: TerminalController.shared.issueInboxStore)
        panels[issueInboxPanel.id] = issueInboxPanel
        panelTitles[issueInboxPanel.id] = issueInboxPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: issueInboxPanel.displayTitle,
            icon: issueInboxPanel.displayIcon,
            kind: SurfaceKind.issueInbox.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: issueInboxPanel.id)
            panelTitles.removeValue(forKey: issueInboxPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: issueInboxPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            issueInboxPanel.id,
            paneId: paneId,
            kind: Self.cmuxEventSurfaceKind(issueInboxPanel),
            origin: "issue_inbox_tab",
            focused: shouldFocusNewTab
        )

        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: issueInboxPanel.id,
                previousHostedView: previousHostedView
            )
        }

        return issueInboxPanel
    }
}
