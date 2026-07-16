import Bonsplit
import Foundation

// MARK: - Mobile pane wire contract and terminal mutations

extension TerminalController {
    enum MobileTerminalAliasUUID {
        case missing
        case value(UUID)
        case invalid
        case conflict
    }

    func mobileTerminalAliasUUID(params: [String: Any]) -> MobileTerminalAliasUUID {
        var selected: UUID?
        var sawAlias = false
        for key in ["surface_id", "terminal_id", "tab_id"] {
            guard v2HasNonNullParam(params, key) else { continue }
            sawAlias = true
            guard let candidate = v2UUID(params, key) else { return .invalid }
            if let selected, selected != candidate { return .conflict }
            selected = selected ?? candidate
        }
        if let selected { return .value(selected) }
        return sawAlias ? .invalid : .missing
    }

    func mobileTerminalAliasValidationError(params: [String: Any]) -> V2CallResult? {
        switch mobileTerminalAliasUUID(params: params) {
        case .missing, .value:
            return nil
        case .invalid:
            return .err(code: "invalid_params", message: "Missing or invalid terminal_id", data: nil)
        case .conflict:
            return .err(code: "invalid_params", message: "Conflicting terminal identifiers", data: nil)
        }
    }

    func mobileWorkspaceIDValidationError(params: [String: Any]) -> V2CallResult? {
        guard v2HasNonNullParam(params, "workspace_id"),
              v2UUID(params, "workspace_id") == nil else {
            return nil
        }
        return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
    }

    func v2MobileTerminalCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        if let error = mobileWorkspaceIDValidationError(params: params) { return error }
        guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }

        let paneId: PaneID
        if v2HasNonNullParam(params, "pane_id") {
            guard let requestedPaneID = v2UUID(params, "pane_id"),
                  workspace.bonsplitController.allPaneIds.contains(where: { $0.id == requestedPaneID }) else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "mobile.terminal.create.error.invalidPane",
                        defaultValue: "Missing or invalid pane_id"
                    ),
                    data: nil
                )
            }
            paneId = PaneID(id: requestedPaneID)
        } else if let defaultPane = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first {
            paneId = defaultPane
        } else {
            return .err(code: "not_found", message: "Pane not found", data: nil)
        }

        guard let terminal = workspace.newTerminalSurface(
            inPane: paneId,
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

    func v2MobileTerminalClose(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) { return error }
        guard let workspaceID = v2UUID(params, "workspace_id") else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "mobile.terminal.close.error.invalidWorkspace",
                    defaultValue: "Missing or invalid workspace_id"
                ),
                data: nil
            )
        }

        let surfaceID: UUID
        switch mobileTerminalAliasUUID(params: params) {
        case let .value(value):
            surfaceID = value
        case .missing, .invalid:
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "mobile.terminal.close.error.invalidTerminal",
                    defaultValue: "Missing or invalid terminal_id"
                ),
                data: nil
            )
        case .conflict:
            return .err(code: "invalid_params", message: "Conflicting terminal identifiers", data: nil)
        }

        guard let tabManager = v2ResolveTabManager(params: params),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }),
              workspace.terminalPanel(for: surfaceID) != nil else {
            return .err(
                code: "not_found",
                message: String(
                    localized: "mobile.terminal.close.error.notFound",
                    defaultValue: "Terminal surface not found"
                ),
                data: ["workspace_id": workspaceID.uuidString, "surface_id": surfaceID.uuidString]
            )
        }
        guard mobileTerminalPanels(in: workspace).count > 1 else {
            return .err(
                code: "last_terminal",
                message: String(
                    localized: "mobile.terminal.close.error.lastTerminal",
                    defaultValue: "The workspace's last terminal can't be closed"
                ),
                data: ["workspace_id": workspaceID.uuidString, "surface_id": surfaceID.uuidString]
            )
        }
        guard closeSurfaceRecordingHistory(in: workspace, surfaceId: surfaceID, force: true) else {
            return .err(
                code: "internal_error",
                message: String(
                    localized: "mobile.terminal.close.error.failed",
                    defaultValue: "Failed to close terminal"
                ),
                data: nil
            )
        }

        switch v2MobileWorkspaceList(
            params: ["workspace_id": workspaceID.uuidString],
            tabManager: tabManager
        ) {
        case let .ok(rawPayload):
            guard var payload = rawPayload as? [String: Any] else {
                return .err(code: "internal_error", message: "Failed to refresh workspace list", data: nil)
            }
            payload["workspace_id"] = workspaceID.uuidString
            payload["surface_id"] = surfaceID.uuidString
            payload["closed"] = true
            return .ok(payload)
        case let .err(code, message, data):
            return .err(code: code, message: message, data: data)
        }
    }

    func mobileTerminalPanels(in workspace: Workspace) -> [TerminalPanel] {
        orderedPanels(in: workspace).compactMap { $0 as? TerminalPanel }
    }

    static func mobilePanePayloads(
        workspace: Workspace,
        includedTerminalIDs: Set<UUID>
    ) -> (panes: [[String: Any]], paneIDByTerminalID: [UUID: UUID]) {
        let snapshot = workspace.bonsplitController.layoutSnapshot()
        var panelIDBySurfaceID: [UUID: UUID] = [:]
        for pane in snapshot.panes {
            for rawSurfaceID in pane.tabIds {
                guard let surfaceID = UUID(uuidString: rawSurfaceID),
                      let panelID = workspace.panelId(forSurfaceId: surfaceID) else { continue }
                panelIDBySurfaceID[surfaceID] = panelID
            }
        }
        return mobilePanePayloads(
            layoutSnapshot: snapshot,
            spatiallyOrderedPaneIDs: workspace.spatiallyOrderedPaneIds,
            panelIDBySurfaceID: panelIDBySurfaceID,
            includedTerminalIDs: includedTerminalIDs
        )
    }

    static func mobilePanePayloads(
        layoutSnapshot: LayoutSnapshot,
        spatiallyOrderedPaneIDs: [UUID],
        panelIDBySurfaceID: [UUID: UUID],
        includedTerminalIDs: Set<UUID>
    ) -> (panes: [[String: Any]], paneIDByTerminalID: [UUID: UUID]) {
        let geometryByPaneID = Dictionary(uniqueKeysWithValues: layoutSnapshot.panes.compactMap { pane in
            UUID(uuidString: pane.paneId).map { ($0, pane) }
        })
        let usesFallbackRects = layoutSnapshot.containerFrame.width <= 0
            || layoutSnapshot.containerFrame.height <= 0
        var paneRows: [(id: UUID, tabIDs: [UUID], selectedTabID: UUID?, isFocused: Bool, rect: [String: Double])] = []
        var paneIDByTerminalID: [UUID: UUID] = [:]

        for paneID in spatiallyOrderedPaneIDs {
            guard let geometry = geometryByPaneID[paneID] else { continue }
            let tabIDs = geometry.tabIds.compactMap { rawSurfaceID -> UUID? in
                guard let surfaceID = UUID(uuidString: rawSurfaceID),
                      let panelID = panelIDBySurfaceID[surfaceID],
                      includedTerminalIDs.contains(panelID) else { return nil }
                paneIDByTerminalID[panelID] = paneID
                return panelID
            }
            guard !tabIDs.isEmpty else { continue }
            let selectedTabID = geometry.selectedTabId
                .flatMap(UUID.init(uuidString:))
                .flatMap { panelIDBySurfaceID[$0] }
                .flatMap { includedTerminalIDs.contains($0) ? $0 : nil }
            let rect: [String: Double]
            if usesFallbackRects {
                rect = [:]
            } else {
                let container = layoutSnapshot.containerFrame
                rect = [
                    "x": (geometry.frame.x - container.x) / container.width,
                    "y": (geometry.frame.y - container.y) / container.height,
                    "w": geometry.frame.width / container.width,
                    "h": geometry.frame.height / container.height,
                ]
            }
            paneRows.append((
                id: paneID,
                tabIDs: tabIDs,
                selectedTabID: selectedTabID,
                isFocused: layoutSnapshot.focusedPaneId == paneID.uuidString,
                rect: rect
            ))
        }

        let fallbackWidth = paneRows.isEmpty ? 0 : 1.0 / Double(paneRows.count)
        let panes = paneRows.enumerated().map { index, pane -> [String: Any] in
            let rect = usesFallbackRects
                ? ["x": Double(index) * fallbackWidth, "y": 0.0, "w": fallbackWidth, "h": 1.0]
                : pane.rect
            return [
                "id": pane.id.uuidString,
                "tab_ids": pane.tabIDs.map(\.uuidString),
                "selected_tab_id": pane.selectedTabID.map { $0.uuidString as Any } ?? NSNull(),
                "is_focused": pane.isFocused,
                "rect": rect,
            ]
        }
        return (panes, paneIDByTerminalID)
    }
}
