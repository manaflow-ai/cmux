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
}
