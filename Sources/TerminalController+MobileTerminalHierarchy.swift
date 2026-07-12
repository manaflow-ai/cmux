import Bonsplit
import Foundation

extension TerminalController {
    func v2MobileTerminalCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        if let error = mobileWorkspaceIDValidationError(params: params) { return error }
        guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        let requestedPaneID = v2UUID(params, "pane_id")
        if v2HasNonNullParam(params, "pane_id"), requestedPaneID == nil {
            return .err(code: "invalid_params", message: "Missing or invalid pane_id", data: nil)
        }
        let paneID: PaneID?
        if let requestedPaneID {
            paneID = workspace.bonsplitController.allPaneIds.first { $0.id == requestedPaneID }
            if paneID == nil {
                return .err(code: "not_found", message: "Pane not found in workspace", data: nil)
            }
        } else {
            paneID = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first
        }
        guard let paneID else { return .err(code: "not_found", message: "Pane not found", data: nil) }
        guard let terminal = workspace.newTerminalSurface(
            inPane: paneID,
            focus: false,
            autoRefreshMetadata: false,
            preserveFocusWhenUnfocused: false,
            inheritWorkingDirectoryFallback: true,
            allowTextBoxFocusDefault: false
        ) else {
            return .err(code: "internal_error", message: "Failed to create terminal", data: nil)
        }
        return v2MobileWorkspaceList(
            params: params,
            tabManager: tabManager,
            createdTerminalID: terminal.id.uuidString
        )
    }

    /// Closes one exact terminal after the iOS consequence UI has confirmed it.
    func v2MobileTerminalClose(params: [String: Any]) -> V2CallResult {
        guard v2UUID(params, "workspace_id") != nil else {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        guard case .value = mobileTerminalAliasUUID(params: params) else {
            return .err(code: "invalid_params", message: "Missing or invalid terminal_id", data: nil)
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: false),
              let surfaceID = resolved.surfaceId,
              resolved.workspace.terminalPanel(for: surfaceID) != nil else {
            return .err(code: "not_found", message: "Terminal not found", data: nil)
        }
        guard resolved.workspace.panels.count > 1 else {
            return .err(code: "invalid_state", message: "The workspace must keep at least one item", data: nil)
        }
        guard !resolved.workspace.pinnedPanelIds.contains(surfaceID) else {
            return .err(code: "protected", message: "Pinned terminals cannot be closed", data: nil)
        }
        if resolved.workspace.panelNeedsConfirmClose(panelId: surfaceID), v2Bool(params, "confirmed") != true {
            return .err(
                code: "confirmation_required",
                message: "Closing this terminal ends its running processes",
                data: ["requires_confirmation": true]
            )
        }
        guard closeSurfaceRecordingHistory(in: resolved.workspace, surfaceId: surfaceID, force: true) else {
            return .err(code: "internal_error", message: "Failed to close terminal", data: nil)
        }
        clearMobileViewportReports(surfaceID: surfaceID, reason: "mobile.terminal.close")
        return .ok([
            "closed": true,
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": surfaceID.uuidString,
        ])
    }

    /// Reorders one terminal inside its current pane without permitting a boundary crossing.
    func v2MobileTerminalReorder(params: [String: Any]) -> V2CallResult {
        guard let workspaceID = v2UUID(params, "workspace_id"),
              let paneUUID = v2UUID(params, "pane_id"),
              let surfaceID = v2UUID(params, "surface_id"),
              let targetIndex = v2Int(params, "index"), targetIndex >= 0 else {
            return .err(code: "invalid_params", message: "Missing terminal reorder target", data: nil)
        }
        guard let tabManager = v2ResolveTabManager(params: params),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }),
              let paneID = workspace.paneId(forPanelId: surfaceID),
              paneID.id == paneUUID,
              workspace.terminalPanel(for: surfaceID) != nil else {
            return .err(code: "not_found", message: "Terminal is not in that workspace and pane", data: nil)
        }
        let panePanelIDs = workspace.bonsplitController.tabs(inPane: paneID).compactMap {
            workspace.panelIdFromSurfaceId($0.id)
        }
        let terminalIDs = Set(panePanelIDs.filter { workspace.terminalPanel(for: $0) != nil })
        guard !MobileTerminalReorderIndexResolver.crossesPinnedBoundary(
            panePanelIDs: panePanelIDs,
            terminalPanelIDs: terminalIDs,
            pinnedPanelIDs: workspace.pinnedPanelIds,
            movingPanelID: surfaceID,
            targetTerminalIndex: targetIndex
        ) else {
            return .err(
                code: "protected",
                message: "Pinned terminals cannot cross the pinned boundary",
                data: nil
            )
        }
        guard let destinationIndex = MobileTerminalReorderIndexResolver.destinationIndex(
            panePanelIDs: panePanelIDs,
            terminalPanelIDs: terminalIDs,
            pinnedPanelIDs: workspace.pinnedPanelIds,
            movingPanelID: surfaceID,
            targetTerminalIndex: targetIndex
        ) else {
            return .err(code: "invalid_params", message: "Terminal reorder index is out of range", data: nil)
        }
        guard workspace.reorderSurface(panelId: surfaceID, toIndex: destinationIndex, focus: false) else {
            return .err(code: "internal_error", message: "Failed to reorder terminal", data: nil)
        }
        return .ok([
            "reordered": true,
            "workspace_id": workspaceID.uuidString,
            "pane_id": paneUUID.uuidString,
            "surface_id": surfaceID.uuidString,
        ])
    }
}
