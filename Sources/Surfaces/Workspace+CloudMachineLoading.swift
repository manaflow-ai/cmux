import CmuxSurfaceCatalogModel
import Foundation
import CmuxWorkspaces

@MainActor
extension Workspace {
    /// Only a machine-bound loading card in this destination can be adopted.
    /// Ordinary terminal panes, including a user's first command, are never placeholders.
    func cloudMachineLoadingPanel(at destination: SurfaceDestination, machineID: String?) -> CloudVMLoadingPanel? {
        guard case .workspace(let workspaceID, _) = destination,
              workspaceID == id, let machineID,
              cloudVMBinding?.vmID == machineID else { return nil }
        let candidates = panels.values.compactMap { $0 as? CloudVMLoadingPanel }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Replaces a creating card with its attached terminal in the same native tab.
    /// There is no local shell, close event, or layout/focus change between them.
    func adoptCloudMachineLoadingPanel(
        _ loading: CloudVMLoadingPanel,
        terminal: TerminalPanel,
        focus: Bool
    ) throws {
        guard !isRetiredFromOwningTabManager,
              panels[loading.id] === loading,
              terminal.id == loading.id,
              let machineID = cloudVMBinding?.vmID,
              terminal.cloudAttachment?.machineID == machineID,
              let tab = surfaceIdFromPanelId(loading.id),
              let pane = paneId(forPanelId: loading.id) else {
            terminal.close()
            throw CancellationError()
        }
        terminal.adoptStableSurfaceId(loading.stableSurfaceId)
        panels[loading.id] = terminal
        let title = String(localized: "cloudTree.terminal.untitled", defaultValue: "terminal")
        panelTitles[loading.id] = title
        bonsplitController.updateTab(
            tab, title: title, icon: .some(terminal.displayIcon),
            iconImageData: .some(nil), iconAsset: .some(nil),
            kind: .some(SurfaceKind.terminal.rawValue),
            hasCustomTitle: false, isDirty: false,
            showsNotificationBadge: false, isLoading: false, isPinned: false
        )
        rememberTerminalConfigInheritanceSource(terminal)
        publishCmuxSurfaceCreated(terminal.id, paneId: pane, kind: SurfaceKind.terminal.rawValue,
                                  origin: "cloud_vm_ready", focused: focus)
        if focus { focusPanel(terminal.id) } else { terminal.unfocus() }
        scheduleTerminalGeometryReconcile()
        if owningTabManager?.selectedTabId == id, focusedPanelId == terminal.id {
            scheduleFocusReconcile()
        }
    }

    /// Restores the creating card in the same native tab after an attachment
    /// receipt fails final placement validation. The pane remains retryable and
    /// keeps its durable surface identity.
    @discardableResult
    func restoreCloudMachineLoadingPanel(panelID: UUID, machineID: String) -> Bool {
        guard let terminal = panels[panelID] as? TerminalPanel,
              cloudVMBinding?.vmID == machineID,
              terminal.cloudAttachment?.machineID == machineID,
              let tab = surfaceIdFromPanelId(panelID) else { return false }
        let loading = CloudVMLoadingPanel(id: panelID, workspaceId: id)
        loading.adoptStableSurfaceId(terminal.stableSurfaceId)
        loading.showFailure(String(localized: "panel.cloudVM.loading.failed.generic", defaultValue: "Cloud VM could not be opened."))
        terminal.close()
        panels[panelID] = loading
        panelTitles[panelID] = loading.displayTitle
        bonsplitController.updateTab(
            tab, title: loading.displayTitle, icon: .some(loading.displayIcon),
            iconImageData: .some(nil), iconAsset: .some(nil),
            kind: .some(SurfaceKind.cloudVMLoading.rawValue),
            hasCustomTitle: false, isDirty: false,
            showsNotificationBadge: false, isLoading: true, isPinned: false
        )
        return true
    }

    /// Removes a still-pending card after an existing terminal projection wins
    /// the reuse race, without touching that projection or user content.
    @discardableResult
    func discardCloudMachineLoadingPanel(panelID: UUID, machineID: String) -> Bool {
        guard cloudVMBinding?.vmID == machineID,
              panels[panelID] is CloudVMLoadingPanel else { return false }
        withClosedPanelHistorySuppressed {
            _ = closePanel(panelID, force: true)
        }
        return true
    }
}
