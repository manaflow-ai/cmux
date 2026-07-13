import AppKit

@MainActor
extension TabManager {
    @discardableResult
    func setOwningWindow(
        _ window: NSWindow?,
        activateRestoredPanel: Bool = true
    ) -> UUID? {
        guard self.window !== window else { return nil }
        var previouslyActiveBrowserPanelID: UUID?
        if let previousWindow = self.window {
            previouslyActiveBrowserPanelID = browserWebExtensionHost?.noteWindowClosed(previousWindow)
            pendingBrowserWebExtensionActivePanelID = previouslyActiveBrowserPanelID
        }
        self.window = window
        guard let window else { return previouslyActiveBrowserPanelID }
        for workspace in tabs {
            reconcileBrowserWebExtensionWindows(
                in: workspace,
                nativeWindow: window,
                activateFocusedPanel: false
            )
            noteUserOwnedPanelsAdded(in: workspace)
        }
        guard activateRestoredPanel else {
            pendingBrowserWebExtensionActivePanelID = nil
            return previouslyActiveBrowserPanelID
        }
        let restoredPanelID = [previouslyActiveBrowserPanelID, pendingBrowserWebExtensionActivePanelID]
            .compactMap { $0 }
            .first(where: ownsReconciledBrowserPanel)
            ?? preferredFocusedBrowserWebExtensionPanelID()
        pendingBrowserWebExtensionActivePanelID = nil
        if let restoredPanelID {
            browserWebExtensionHost?.noteActivated(panelID: restoredPanelID)
        }
        return previouslyActiveBrowserPanelID
    }

    func browserWebExtensionPanelIDs() -> [UUID] {
        tabs.flatMap { workspace in
            let workspacePanelIDs = workspace.panels.compactMap { panelID, panel in
                panel is BrowserPanel ? panelID : nil
            }
            let dockPanelIDs = workspace._dockSplit?.panels.compactMap { panelID, panel in
                panel is BrowserPanel ? panelID : nil
            } ?? []
            return workspacePanelIDs + dockPanelIDs
        }
    }

    func noteUserOwnedPanelsAdded(in workspace: Workspace) {
        guard workspace.panels.values.contains(where: { !($0 is BrowserPanel) }) else { return }
        let workspaceBrowserPanelIDs = workspace.panels.compactMap {
            $0.value is BrowserPanel ? $0.key : nil
        }
        browserWebExtensionHost?.noteUserOwnedPanelAdded(
            nativeWindow: window,
            alongsidePanelIDs: browserWebExtensionPanelIDs() + workspaceBrowserPanelIDs
        )
    }

    func discardBrowserWebExtensionWindowOwnership() {
        let panelIDs = browserWebExtensionPanelIDs()
        browserWebExtensionHost?.discardWindowOwnership(panelIDs: panelIDs)
        pendingBrowserWebExtensionActivePanelID = nil
    }

    func containsOnlyBrowserWebExtensionClosablePanels() -> Bool {
        let mainPanels = tabs.flatMap { Array($0.panels.values) }
        let workspaceDockPanels = tabs.flatMap { workspace in
            workspace._dockSplit.map { Array($0.panels.values) } ?? []
        }
        let panels = mainPanels + workspaceDockPanels
        return !panels.isEmpty && panels.allSatisfy { $0 is BrowserPanel }
    }

    func reconcileBrowserWebExtensionWindows(
        in workspace: Workspace,
        nativeWindow: NSWindow?,
        activateFocusedPanel: Bool = true
    ) {
        let browserPanels = workspace.panels.values.compactMap { $0 as? BrowserPanel }
        for browserPanel in browserPanels {
            AppDelegate.shared?.noteRecoverableBrowserWebExtensionPanelRegistered(
                panelID: browserPanel.id,
                workspaceID: workspace.id
            )
        }
        guard let nativeWindow else { return }
        for browserPanel in browserPanels {
            browserPanel.browserWebExtensionHost?.noteWindowChanged(
                panelID: browserPanel.id,
                nativeWindow: nativeWindow
            )
        }
        workspace._dockSplit?.reconcileBrowserWebExtensionWindows(
            in: nativeWindow,
            activateFocusedPanel: activateFocusedPanel
        )
        if activateFocusedPanel,
           let focusedPanelID = focusedBrowserWebExtensionPanelID(in: workspace) {
            browserWebExtensionHost?.noteActivated(panelID: focusedPanelID)
        }
    }

    private func preferredFocusedBrowserWebExtensionPanelID() -> UUID? {
        if let selectedWorkspace,
           let panelID = focusedBrowserWebExtensionPanelID(in: selectedWorkspace) {
            return panelID
        }
        return tabs.lazy.compactMap { self.focusedBrowserWebExtensionPanelID(in: $0) }.first
    }

    private func focusedBrowserWebExtensionPanelID(in workspace: Workspace) -> UUID? {
        guard let panelID = workspace.focusedPanelId,
              workspace.panels[panelID] is BrowserPanel else { return nil }
        return panelID
    }

    private func ownsReconciledBrowserPanel(_ panelID: UUID) -> Bool {
        tabs.contains { workspace in
            workspace.panels[panelID] is BrowserPanel
                || workspace._dockSplit?.containsPanel(panelID) == true
        }
    }
}
