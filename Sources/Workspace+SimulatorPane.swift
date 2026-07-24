import Bonsplit
import CmuxWorkspaces
import Foundation

extension Workspace {
    /// Returns whether a Simulator panel can accept at least one external file.
    /// Returns `nil` when the target panel is not a Simulator.
    func canHandleSimulatorExternalFileDrop(
        urls: [URL],
        panelId: UUID
    ) -> Bool? {
        guard let panel = panels[panelId] as? SimulatorPanel else { return nil }
        guard CmuxFeatureFlags.shared.isSimulatorEnabled,
              panel.isFeatureReady,
              !urls.isEmpty else {
            return false
        }
        return panel.coordinator.canImportDroppedFiles(urls)
    }

    /// Imports external files into a Simulator panel without creating file-preview tabs.
    /// Returns `nil` when the target panel is not a Simulator.
    func handleSimulatorExternalFileDrop(urls: [URL], panelId: UUID) -> Bool? {
        guard let canHandle = canHandleSimulatorExternalFileDrop(
            urls: urls,
            panelId: panelId
        ) else {
            return nil
        }
        guard canHandle,
              let panel = panels[panelId] as? SimulatorPanel else {
            return false
        }
        let coordinator = panel.coordinator
        Task { @MainActor in await coordinator.importDroppedFiles(urls) }
        return true
    }

    /// Creates a native Simulator tab in an existing pane.
    @discardableResult
    func newSimulatorSurface(
        inPane paneId: PaneID,
        preferredDeviceID: String? = nil,
        preferredRuntimeIdentifier: String? = nil,
        preferredDeviceTypeIdentifier: String? = nil,
        focus: Bool? = nil,
        targetIndex: Int? = nil,
        restoringSession: Bool = false
    ) -> SimulatorPanel? {
        guard (CmuxFeatureFlags.shared.isSimulatorEnabled || restoringSession),
              !isRemoteTmuxMirror else { return nil }
        let shouldFocus = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView
        let panel = SimulatorPanel(
            preferredDeviceID: preferredDeviceID,
            preferredRuntimeIdentifier: preferredRuntimeIdentifier,
            preferredDeviceTypeIdentifier: preferredDeviceTypeIdentifier,
            requiresExplicitDeviceSelection: restoringSession && preferredDeviceID == nil
        )
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle

        guard let tabId = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.simulator.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            panel.close()
            return nil
        }

        bindSurface(tabId, toPanelId: panel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(tabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            panel.id,
            paneId: paneId,
            kind: SurfaceKind.simulator.rawValue,
            origin: "simulator_tab",
            focused: shouldFocus
        )

        if shouldFocus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            applyTabSelection(tabId: tabId, inPane: paneId)
        } else if let previousFocusedPanelId {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: panel.id,
                previousHostedView: previousHostedView
            )
        }
        return panel
    }

    /// Creates a native Simulator in a new split pane.
    @discardableResult
    func newSimulatorSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        preferredDeviceID: String? = nil,
        preferredRuntimeIdentifier: String? = nil,
        preferredDeviceTypeIdentifier: String? = nil,
        focus: Bool = true,
        initialDividerPosition: CGFloat? = nil
    ) -> SimulatorPanel? {
        guard CmuxFeatureFlags.shared.isSimulatorEnabled,
              !isRemoteTmuxMirror,
              let sourceTabId = surfaceIdFromPanelId(panelId),
              let sourcePaneId = bonsplitController.allPaneIds.first(where: { paneId in
                  bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == sourceTabId })
              }) else {
            return nil
        }

        let panel = SimulatorPanel(
            preferredDeviceID: preferredDeviceID,
            preferredRuntimeIdentifier: preferredRuntimeIdentifier,
            preferredDeviceTypeIdentifier: preferredDeviceTypeIdentifier
        )
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle
        let tab = Bonsplit.Tab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.simulator.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false
        )
        bindSurface(tab.id, toPanelId: panel.id)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(
            sourcePaneId,
            orientation: orientation,
            withTab: tab,
            insertFirst: insertFirst
        ) else {
            removeSurfaceMapping(forSurfaceId: tab.id)
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            panel.close()
            return nil
        }

        applyInitialSplitDividerPosition(
            initialDividerPosition,
            sourcePaneId: sourcePaneId,
            newPaneId: newPaneId
        )
        publishCmuxSplitCreated(
            newPaneId,
            sourcePaneId: sourcePaneId,
            orientation: orientation,
            surfaceId: panel.id,
            kind: SurfaceKind.simulator.rawValue,
            origin: "simulator_split",
            focused: focus
        )

        if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.simulatorSplitReparent"
            )
            focusPanel(panel.id, previousHostedView: previousHostedView)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: panel.id,
                previousHostedView: previousHostedView
            )
        }
        return panel
    }
}
