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
        self.init(
            workspace: workspace,
            previewSignature: previewSignature,
            fallbackNeedsConfirmClose: { panelID in
                workspace.terminalPanel(for: panelID)?.needsConfirmClose() ?? false
            }
        )
    }

    @MainActor
    init(
        workspace: Workspace,
        previewSignature: Int? = nil,
        fallbackNeedsConfirmClose: (UUID) -> Bool
    ) {
        let focusValue = FocusValue(workspace: workspace)
        let paneSample = Self.paneListSample(workspace: workspace)
        let orderedPanelIDs = workspace.orderedPanelIds
        let terminalListValues = Self.terminalListValues(
            workspace: workspace,
            orderedPanelIDs: orderedPanelIDs,
            paneIDByTerminalID: paneSample.paneIDByTerminalID,
            samplesCloseConfirmationFallback: true,
            fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
        )
        list = Self.listValue(
            workspace: workspace,
            previewSignature: previewSignature,
            orderedPanelIDs: orderedPanelIDs,
            panes: paneSample.values,
            terminals: terminalListValues
        )
        focus = focusValue
        panes = paneSample.values.map { pane in
            PanePayloadValue(
                id: pane.id,
                spatialIndex: pane.spatialIndex,
                isFocused: pane.id == focusValue.focusedPaneID,
                terminalIDs: pane.terminalIDs
            )
        }
        terminals = terminalListValues.map { terminal in
            TerminalPayloadValue(
                list: terminal,
                isFocused: terminal.id == workspace.focusedPanelId
            )
        }
    }

    /// Samples only observer-backed list identity. Close confirmation is a
    /// payload-only field with no matching publisher, so this path never asks
    /// Ghostty for its process-state fallback.
    @MainActor
    static func observerListValue(
        workspace: Workspace,
        previewSignature: Int?,
        fallbackNeedsConfirmClose: (UUID) -> Bool
    ) -> ListValue {
        let paneSample = paneListSample(workspace: workspace)
        let orderedPanelIDs = workspace.orderedPanelIds
        let terminals = terminalListValues(
            workspace: workspace,
            orderedPanelIDs: orderedPanelIDs,
            paneIDByTerminalID: paneSample.paneIDByTerminalID,
            samplesCloseConfirmationFallback: false,
            fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
        )
        return listValue(
            workspace: workspace,
            previewSignature: previewSignature,
            orderedPanelIDs: orderedPanelIDs,
            panes: paneSample.values,
            terminals: terminals
        )
    }

    @MainActor
    private static func paneListSample(
        workspace: Workspace
    ) -> (values: [PaneListValue], paneIDByTerminalID: [UUID: UUID]) {
        var paneIDByTerminalID: [UUID: UUID] = [:]
        let values = workspace.bonsplitController.allPaneIds.enumerated().map { spatialIndex, paneID in
            let terminalIDs = workspace.bonsplitController.tabs(inPane: paneID).compactMap { tab -> UUID? in
                guard let panelID = workspace.panelIdFromSurfaceId(tab.id),
                      workspace.terminalPanel(for: panelID) != nil else {
                    return nil
                }
                paneIDByTerminalID[panelID] = paneID.id
                return panelID
            }
            return PaneListValue(id: paneID.id, spatialIndex: spatialIndex, terminalIDs: terminalIDs)
        }
        return (values, paneIDByTerminalID)
    }

    @MainActor
    private static func terminalListValues(
        workspace: Workspace,
        orderedPanelIDs: [UUID],
        paneIDByTerminalID: [UUID: UUID],
        samplesCloseConfirmationFallback: Bool,
        fallbackNeedsConfirmClose: (UUID) -> Bool
    ) -> [TerminalListValue] {
        orderedPanelIDs.compactMap { panelID in
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
            let requiresCloseConfirmation = samplesCloseConfirmationFallback
                ? workspace.panelNeedsConfirmClose(
                    panelId: terminal.id,
                    fallbackNeedsConfirmClose: { fallbackNeedsConfirmClose(terminal.id) }
                )
                : false
            return TerminalListValue(
                id: terminal.id,
                title: workspace.panelTitle(panelId: terminal.id) ?? terminal.displayTitle,
                currentDirectory: directory,
                paneID: paneIDByTerminalID[terminal.id],
                canClose: workspace.panels.count > 1 && !workspace.pinnedPanelIds.contains(terminal.id),
                requiresCloseConfirmation: requiresCloseConfirmation,
                isReady: terminal.surface.surface != nil
            )
        }
    }

    @MainActor
    private static func listValue(
        workspace: Workspace,
        previewSignature: Int?,
        orderedPanelIDs: [UUID],
        panes: [PaneListValue],
        terminals: [TerminalListValue]
    ) -> ListValue {
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
        return ListValue(
            schemaVersion: Self.schemaVersion,
            id: workspace.id,
            title: workspace.title,
            isPinned: workspace.isPinned,
            groupID: workspace.groupId,
            previewSignature: previewSignature,
            orderedPanelIDs: orderedPanelIDs,
            pinnedPanelIDs: workspace.pinnedPanelIds.sorted { $0.uuidString < $1.uuidString },
            panes: panes,
            terminals: terminals,
            surfaces: surfaces,
            currentDirectory: workspace.presentedCurrentDirectory,
            panelDirectories: panelDirectories
        )
    }
}
