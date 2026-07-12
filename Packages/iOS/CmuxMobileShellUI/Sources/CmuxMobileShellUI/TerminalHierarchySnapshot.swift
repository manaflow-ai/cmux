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
        connectionStatus = workspace.macConnectionStatus ?? .unavailable
        let titleCounts = Dictionary(grouping: workspace.terminals, by: \.name).mapValues(\.count)
        var titleOrdinals: [String: Int] = [:]
        var terminalsByID: [MobileTerminalPreview.ID: MobileTerminalPreview] = [:]
        var duplicateOrdinalByID: [MobileTerminalPreview.ID: Int] = [:]
        for terminal in workspace.terminals {
            terminalsByID[terminal.id] = terminal
            if titleCounts[terminal.name, default: 0] > 1 {
                titleOrdinals[terminal.name, default: 0] += 1
                duplicateOrdinalByID[terminal.id] = titleOrdinals[terminal.name]
            }
        }
        panes = workspace.resolvedPanes.map { pane in
            var seenTerminalIDs: Set<MobileTerminalPreview.ID> = []
            return TerminalHierarchyPaneSnapshot(
                id: pane.id,
                spatialIndex: pane.spatialIndex,
                isFocused: pane.isFocused,
                rows: pane.terminalIDs.compactMap { terminalID in
                    guard seenTerminalIDs.insert(terminalID).inserted else { return nil }
                    guard let terminal = terminalsByID[terminalID] else { return nil }
                    return TerminalHierarchyRowSnapshot(
                        id: terminal.id,
                        title: terminal.name,
                        duplicateOrdinal: duplicateOrdinalByID[terminal.id],
                        workspaceName: workspace.name,
                        paneNumber: pane.spatialIndex + 1,
                        isSelected: terminal.id == selectedTerminalID,
                        isReady: terminal.isReady,
                        canClose: terminal.canClose && workspace.actionCapabilities.supportsTerminalCloseActions,
                        requiresCloseConfirmation: terminal.requiresCloseConfirmation
                    )
                },
                pane: pane
            )
        }
    }
}
