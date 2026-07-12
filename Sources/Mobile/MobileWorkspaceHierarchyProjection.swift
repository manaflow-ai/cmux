import CmuxWorkspaces
import Foundation

/// Immutable, versioned value sampled from the Mac hierarchy on the main actor.
/// Publishers and focus notifications only request a new sample. They are never
/// treated as the state carried by an event, which avoids mixing `willSet`
/// values with later live reads from other hierarchy dimensions.
struct MobileWorkspaceHierarchyProjection {
    static let schemaVersion = 1

    let list: ListValue
    let focus: FocusValue
    let panes: [PanePayloadValue]
    let terminals: [TerminalPayloadValue]

    @MainActor
    init(workspace: Workspace, previewSignature: Int? = nil) {
        let focusValue = FocusValue(workspace: workspace)
        let paneIDs = workspace.bonsplitController.allPaneIds
        var paneIDByTerminalID: [UUID: UUID] = [:]
        var paneListValues: [PaneListValue] = []
        var panePayloadValues: [PanePayloadValue] = []
        for (spatialIndex, paneID) in paneIDs.enumerated() {
            let terminalIDs = workspace.bonsplitController.tabs(inPane: paneID).compactMap { tab -> UUID? in
                guard let panelID = workspace.panelIdFromSurfaceId(tab.id),
                      workspace.terminalPanel(for: panelID) != nil else {
                    return nil
                }
                paneIDByTerminalID[panelID] = paneID.id
                return panelID
            }
            paneListValues.append(.init(id: paneID.id, spatialIndex: spatialIndex, terminalIDs: terminalIDs))
            panePayloadValues.append(.init(
                id: paneID.id,
                spatialIndex: spatialIndex,
                isFocused: paneID.id == focusValue.focusedPaneID,
                terminalIDs: terminalIDs
            ))
        }

        let orderedPanelIDs = workspace.orderedPanelIds
        let terminalValues = orderedPanelIDs.compactMap { panelID -> TerminalPayloadValue? in
            guard let terminal = workspace.terminalPanel(for: panelID) else { return nil }
            let localDirectory = [terminal.directory, terminal.requestedWorkingDirectory]
                .compactMap { raw -> String? in
                    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return raw
                }
                .first
            let directory = workspace.effectivePanelDirectory(
                panelId: terminal.id,
                localFallback: localDirectory
            )
            return .init(
                list: .init(
                    id: terminal.id,
                    title: workspace.panelTitle(panelId: terminal.id) ?? terminal.displayTitle,
                    currentDirectory: directory,
                    paneID: paneIDByTerminalID[terminal.id],
                    canClose: workspace.panels.count > 1 && !workspace.pinnedPanelIds.contains(terminal.id),
                    requiresCloseConfirmation: workspace.panelNeedsConfirmClose(
                        panelId: terminal.id,
                        fallbackNeedsConfirmClose: { terminal.needsConfirmClose() }
                    ),
                    isReady: terminal.surface.surface != nil
                ),
                isFocused: terminal.id == workspace.focusedPanelId
            )
        }
        let surfaces = orderedPanelIDs.map {
            SurfaceListValue(
                id: $0,
                title: workspace.panelTitle(panelId: $0),
                reportedDirectory: workspace.reportedPanelDirectory(panelId: $0)
            )
        }
        let panelDirectories = workspace.panelDirectories.keys
            .sorted { $0.uuidString < $1.uuidString }
            .map { PanelDirectoryValue(id: $0, directory: workspace.panelDirectories[$0]) }
        list = .init(
            schemaVersion: Self.schemaVersion,
            id: workspace.id,
            title: workspace.title,
            isPinned: workspace.isPinned,
            groupID: workspace.groupId,
            previewSignature: previewSignature,
            orderedPanelIDs: orderedPanelIDs,
            pinnedPanelIDs: workspace.pinnedPanelIds.sorted { $0.uuidString < $1.uuidString },
            panes: paneListValues,
            terminals: terminalValues.map(\.list),
            surfaces: surfaces,
            currentDirectory: workspace.presentedCurrentDirectory,
            panelDirectories: panelDirectories
        )
        focus = focusValue
        panes = panePayloadValues
        terminals = terminalValues
    }
}
