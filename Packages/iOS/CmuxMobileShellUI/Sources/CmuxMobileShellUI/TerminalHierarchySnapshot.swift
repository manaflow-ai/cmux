import CmuxMobileShellModel

struct TerminalHierarchySnapshot: Equatable {
    let workspaceID: MobileWorkspacePreview.ID
    let workspaceName: String
    let panes: [TerminalHierarchyPaneSnapshot]
    let canReorder: Bool
    let connectionStatus: MobileMacConnectionStatus

    init(workspace: MobileWorkspacePreview, selectedTerminalID: MobileTerminalPreview.ID?) {
        workspaceID = workspace.id
        workspaceName = workspace.name
        canReorder = workspace.actionCapabilities.supportsTerminalReorderActions
        connectionStatus = workspace.macConnectionStatus ?? .connected
        let titleCounts = Dictionary(grouping: workspace.terminals, by: \.name).mapValues(\.count)
        var titleOrdinals: [String: Int] = [:]
        var rowsByID: [MobileTerminalPreview.ID: TerminalHierarchyRowSnapshot] = [:]
        for terminal in workspace.terminals {
            let ordinal: Int?
            if titleCounts[terminal.name, default: 0] > 1 {
                titleOrdinals[terminal.name, default: 0] += 1
                ordinal = titleOrdinals[terminal.name]
            } else {
                ordinal = nil
            }
            rowsByID[terminal.id] = TerminalHierarchyRowSnapshot(
                id: terminal.id,
                title: terminal.name,
                duplicateOrdinal: ordinal,
                isSelected: terminal.id == selectedTerminalID,
                isReady: terminal.isReady,
                canClose: terminal.canClose && workspace.actionCapabilities.supportsTerminalCloseActions,
                requiresCloseConfirmation: terminal.requiresCloseConfirmation
            )
        }
        panes = workspace.resolvedPanes.map { pane in
            TerminalHierarchyPaneSnapshot(
                id: pane.id,
                spatialIndex: pane.spatialIndex,
                isFocused: pane.isFocused,
                rows: pane.terminalIDs.compactMap { rowsByID[$0] },
                pane: pane
            )
        }
    }
}
