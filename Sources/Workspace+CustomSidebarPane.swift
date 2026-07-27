import Bonsplit
import Foundation
import CmuxWorkspaces

extension Workspace {
    func customSidebarSessionSnapshot(for panel: any Panel) -> SessionCustomSidebarPanelSnapshot? {
        guard let customSidebarPanel = panel as? CustomSidebarPanel else { return nil }
        return SessionCustomSidebarPanelSnapshot(name: customSidebarPanel.name)
    }

    func restoreCustomSidebarPanel(from snapshot: SessionPanelSnapshot, inPane paneId: PaneID) -> UUID? {
        guard let name = snapshot.customSidebar?.name,
              let customSidebarPanel = newCustomSidebarSurface(inPane: paneId, name: name, focus: false) else {
            return nil
        }
        applySessionPanelMetadata(snapshot, toPanelId: customSidebarPanel.id)
        return customSidebarPanel.id
    }

    @discardableResult
    func openOrFocusCustomSidebarSurface(
        inPane paneId: PaneID,
        name rawName: String,
        focus: Bool = true
    ) -> CustomSidebarPanel? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        for (existingId, panel) in panels {
            guard let customPanel = panel as? CustomSidebarPanel,
                  customPanel.name == name else {
                continue
            }
            if focus {
                focusPanel(existingId)
            }
            return customPanel
        }
        return newCustomSidebarSurface(inPane: paneId, name: name, focus: focus)
    }

    @discardableResult
    func openOrFocusCustomSidebarSplit(
        from panelId: UUID,
        name rawName: String
    ) -> CustomSidebarPanel? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        for (existingId, panel) in panels {
            guard let customPanel = panel as? CustomSidebarPanel,
                  customPanel.name == name else {
                continue
            }
            focusPanel(existingId)
            return customPanel
        }

        if let targetPane = preferredRightSideTargetPane(fromPanelId: panelId) {
            return newCustomSidebarSurface(inPane: targetPane, name: name, focus: true)
        }

        guard let sourcePaneId = paneId(forPanelId: panelId) else { return nil }
        return splitPaneWithCustomSidebar(
            targetPane: sourcePaneId,
            orientation: .horizontal,
            insertFirst: false,
            name: name
        )
    }

    @discardableResult
    func newCustomSidebarSurface(
        inPane paneId: PaneID,
        name rawName: String,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> CustomSidebarPanel? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fileURL = CmuxExtensionSidebarSelection.customSidebarFileURL(forName: name) else {
            return nil
        }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let customPanel = CustomSidebarPanel(workspace: self, name: name, fileURL: fileURL)
        panels[customPanel.id] = customPanel
        panelTitles[customPanel.id] = customPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: customPanel.displayTitle,
            icon: customPanel.displayIcon,
            kind: SurfaceKind.customSidebar.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: customPanel.id)
            panelTitles.removeValue(forKey: customPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: customPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            customPanel.id,
            paneId: paneId,
            kind: Self.cmuxEventSurfaceKind(customPanel),
            origin: "custom_sidebar_tab",
            focused: shouldFocusNewTab
        )

        if shouldFocusNewTab {
            focusPanel(customPanel.id)
        } else if let previousFocusedPanelId {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: customPanel.id,
                previousHostedView: previousHostedView
            )
        }

        return customPanel
    }

    @discardableResult
    func splitPaneWithCustomSidebar(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        name rawName: String
    ) -> CustomSidebarPanel? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fileURL = CmuxExtensionSidebarSelection.customSidebarFileURL(forName: name) else {
            return nil
        }

        let customPanel = CustomSidebarPanel(workspace: self, name: name, fileURL: fileURL)
        panels[customPanel.id] = customPanel
        panelTitles[customPanel.id] = customPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: customPanel.displayTitle,
            icon: customPanel.displayIcon,
            kind: SurfaceKind.customSidebar.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: customPanel.id)
        let previousHostedView = focusedTerminalPanel?.hostedView

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            withTab: newTab,
            insertFirst: insertFirst
        ) else {
            panels.removeValue(forKey: customPanel.id)
            panelTitles.removeValue(forKey: customPanel.id)
            removeSurfaceMapping(forSurfaceId: newTab.id)
            return nil
        }

        bonsplitController.selectTab(newTab.id)
        suppressReparentFocusUntilLayoutFollowUp(
            previousHostedView,
            reason: "workspace.customSidebarSplitReparent"
        )
        focusPanel(customPanel.id, previousHostedView: previousHostedView)
        publishCmuxSplitCreated(
            newPaneId,
            sourcePaneId: paneId,
            orientation: orientation,
            surfaceId: customPanel.id,
            kind: Self.cmuxEventSurfaceKind(customPanel),
            origin: "custom_sidebar_split",
            focused: true
        )
        return customPanel
    }
}
