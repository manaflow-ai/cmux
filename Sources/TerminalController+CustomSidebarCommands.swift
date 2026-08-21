import AppKit
import CmuxControlSocket
import CmuxSettings
import CmuxSwiftRenderUI
import Foundation

extension TerminalController {
    nonisolated func v2CustomSidebarValidate(params: [String: Any]) -> V2CallResult {
        let name = v2CustomSidebarName(params: params)
        if let name, name.isEmpty {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.sidebar.custom.invalidName", defaultValue: "Sidebar name must not be empty."),
                data: nil
            )
        }
        let report = v2CustomSidebarValidationReport(name: name)
        return .ok(v2CustomSidebarReportPayload(report))
    }

    nonisolated func v2CustomSidebarReload(params: [String: Any]) -> V2CallResult {
        let name = v2CustomSidebarName(params: params)
        if let name, name.isEmpty {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.sidebar.custom.invalidName", defaultValue: "Sidebar name must not be empty."),
                data: nil
            )
        }
        let report = v2CustomSidebarValidationReport(name: name)
        let validNames = report.validNames
        let reloadNames = report.names
        if !reloadNames.isEmpty {
            v2MainSync {
                NotificationCenter.default.post(
                    name: .customSidebarReloadRequested,
                    object: nil,
                    userInfo: ["names": reloadNames]
                )
            }
        }
        var payload = v2CustomSidebarReportPayload(report)
        payload["reloaded_count"] = validNames.count
        payload["reloaded_names"] = validNames
        return .ok(payload)
    }

    nonisolated func v2CustomSidebarSelect(params: [String: Any]) -> V2CallResult {
        guard let name = v2CustomSidebarName(params: params), !name.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.sidebar.custom.selectMissingName", defaultValue: "Select requires a sidebar name."),
                data: nil
            )
        }

        let report = v2CustomSidebarValidationReport(name: name)
        guard let entry = report.entries.first else {
            return .ok(v2CustomSidebarReportPayload(report))
        }
        if let errorMessage = entry.errorMessage {
            var payload = v2CustomSidebarReportPayload(report)
            payload["message"] = errorMessage
            return .ok(payload)
        }

        let providerId = CmuxExtensionSidebarSelection.customSidebarProviderPrefix + name
        v2MainSync {
            UserDefaults.standard.set(true, forKey: SettingCatalog().betaFeatures.customSidebars.userDefaultsKey)
            CmuxExtensionSidebarSelection.setProviderId(providerId)
            NotificationCenter.default.post(
                name: .customSidebarReloadRequested,
                object: nil,
                userInfo: ["names": [name]]
            )
        }
        var payload = v2CustomSidebarReportPayload(report)
        payload["selected_provider_id"] = providerId
        payload["selected_name"] = name
        return .ok(payload)
    }

    nonisolated func v2CustomSidebarOpen(params: [String: Any]) -> V2CallResult {
        guard let name = v2CustomSidebarName(params: params), !name.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.sidebar.custom.openMissingName", defaultValue: "Open requires a sidebar name."),
                data: nil
            )
        }

        let report = v2CustomSidebarValidationReport(name: name)
        guard let entry = report.entries.first else {
            return .err(
                code: "validation_failed",
                message: String(localized: "socket.sidebar.custom.missing", defaultValue: "Sidebar file is missing."),
                data: v2CustomSidebarReportPayload(report)
            )
        }
        if let errorMessage = entry.errorMessage {
            var payload = v2CustomSidebarReportPayload(report)
            payload["message"] = errorMessage
            return .err(code: "validation_failed", message: errorMessage, data: payload)
        }

        return v2MainSync {
            if v2HasNonNullParam(params, "window_id"), v2UUID(params, "window_id") == nil {
                return .err(
                    code: "invalid_params",
                    message: String(localized: "socket.sidebar.custom.openInvalidWindowId", defaultValue: "Missing or invalid window_id"),
                    data: nil
                )
            }
            if v2HasNonNullParam(params, "workspace_id"), v2UUID(params, "workspace_id") == nil {
                return .err(
                    code: "invalid_params",
                    message: String(localized: "socket.sidebar.custom.openInvalidWorkspaceId", defaultValue: "Missing or invalid workspace_id"),
                    data: nil
                )
            }
            guard let tabManager = v2CustomSidebarTabManager(params: params) else {
                return .err(
                    code: "tab_manager_unavailable",
                    message: String(localized: "socket.sidebar.custom.openNoWindow", defaultValue: "Unable to access the target workspace."),
                    data: nil
                )
            }
            let workspace: Workspace?
            if let workspaceId = v2UUID(params, "workspace_id") {
                workspace = tabManager.tabs.first { $0.id == workspaceId }
            } else {
                workspace = tabManager.selectedWorkspace ?? tabManager.tabs.first
            }
            guard let workspace else {
                return .err(
                    code: "workspace_not_found",
                    message: String(localized: "socket.sidebar.custom.openNoWorkspace", defaultValue: "Workspace not found."),
                    data: nil
                )
            }

            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: workspace)

            let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
            if focus {
                workspace.clearSplitZoom()
            }
            var panel: CustomSidebarPanel?
            if focus, let focusedPanelId = workspace.focusedPanelId {
                panel = workspace.openOrFocusCustomSidebarSplit(from: focusedPanelId, name: name)
            }
            if panel == nil, let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first {
                panel = workspace.openOrFocusCustomSidebarSurface(inPane: paneId, name: name, focus: focus)
            }
            guard let panel else {
                return .err(
                    code: "surface_create_failed",
                    message: String(localized: "socket.sidebar.custom.openFailed", defaultValue: "Failed to open custom sidebar pane."),
                    data: ["name": name]
                )
            }

            var payload = v2CustomSidebarReportPayload(report)
            payload["opened_name"] = name
            payload["workspace_id"] = workspace.id.uuidString
            payload["workspace_ref"] = v2Ref(kind: .workspace, uuid: workspace.id)
            payload["surface_id"] = panel.id.uuidString
            payload["surface_ref"] = v2Ref(kind: .surface, uuid: panel.id)
            payload["tab_ref"] = v2TabRef(uuid: panel.id)
            payload["type"] = PanelType.customSidebar.rawValue
            return .ok(payload)
        }
    }

    nonisolated func v2SidebarCreationContextList(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let tabManager = v2CustomSidebarTabManager(params: params) else {
                return .err(
                    code: "tab_manager_unavailable",
                    message: String(
                        localized: "socket.sidebar.context.noWindow",
                        defaultValue: "Unable to access the target window."
                    ),
                    data: nil
                )
            }
            return .ok(v2SidebarCreationContextPayload(tabManager: tabManager))
        }
    }

    nonisolated func v2SidebarMachineAddSSH(params: [String: Any]) -> V2CallResult {
        guard let rawDestination = params["host"] as? String else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.machine.hostRequired",
                    defaultValue: "host is required."
                ),
                data: nil
            )
        }
        if v2HasNonNullParam(params, "port"), v2Int(params, "port") == nil {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.machine.invalidPort",
                    defaultValue: "port must be an integer from 1 through 65535."
                ),
                data: nil
            )
        }
        let port = v2Int(params, "port")
        guard port.map({ (1...65535).contains($0) }) ?? true else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.machine.invalidPort",
                    defaultValue: "port must be an integer from 1 through 65535."
                ),
                data: nil
            )
        }
        let identityFile = params["identity_file"] as? String
        let sshOptions: [String]
        if let rawOptions = params["ssh_options"] {
            guard let options = rawOptions as? [String] else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "socket.sidebar.machine.invalidSSHOptions",
                        defaultValue: "ssh_options must be an array of strings."
                    ),
                    data: nil
                )
            }
            sshOptions = options
        } else {
            sshOptions = []
        }
        return v2MainSync {
            guard let tabManager = v2CustomSidebarTabManager(params: params) else {
                return .err(
                    code: "tab_manager_unavailable",
                    message: String(
                        localized: "socket.sidebar.context.noWindow",
                        defaultValue: "Unable to access the target window."
                    ),
                    data: nil
                )
            }
            let shouldSelect = v2Bool(params, "select") ?? false
            guard let contextID = tabManager.addSidebarSSHMachine(
                destination: rawDestination,
                port: port,
                identityFile: identityFile,
                sshOptions: sshOptions,
                select: shouldSelect
            ) else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "socket.sidebar.machine.invalidHost",
                        defaultValue: "The SSH host is invalid."
                    ),
                    data: nil
                )
            }
            var payload = v2SidebarCreationContextPayload(tabManager: tabManager)
            payload["added_context_id"] = contextID
            return .ok(payload)
        }
    }

    nonisolated func v2SidebarMachineAttachCmuxTUI(params: [String: Any]) -> V2CallResult {
        guard let rawContextID = params["context_id"] as? String,
              !rawContextID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.context.missingId",
                    defaultValue: "context_id is required."
                ),
                data: nil
            )
        }
        let contextID = rawContextID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = (params["session"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? SidebarRemoteCmuxTUIAttachCommand.defaultSessionName
        if v2HasNonNullParam(params, "workspace_id"), v2UUID(params, "workspace_id") == nil {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.custom.openInvalidWorkspaceId",
                    defaultValue: "Missing or invalid workspace_id"
                ),
                data: nil
            )
        }
        return v2MainSync {
            guard let tabManager = v2CustomSidebarTabManager(params: params) else {
                return .err(
                    code: "tab_manager_unavailable",
                    message: String(
                        localized: "socket.sidebar.context.noWindow",
                        defaultValue: "Unable to access the target window."
                    ),
                    data: nil
                )
            }
            let workspaceID = v2UUID(params, "workspace_id")
            let workspace = workspaceID.flatMap { id in tabManager.tabs.first { $0.id == id } }
                ?? tabManager.selectedWorkspace
            guard let workspace else {
                return .err(
                    code: "workspace_not_found",
                    message: String(
                        localized: "socket.sidebar.custom.openNoWorkspace",
                        defaultValue: "Workspace not found."
                    ),
                    data: nil
                )
            }
            if let workspaceID, workspace.id != workspaceID {
                return .err(
                    code: "workspace_not_found",
                    message: String(
                        localized: "socket.sidebar.custom.openNoWorkspace",
                        defaultValue: "Workspace not found."
                    ),
                    data: ["workspace_id": workspaceID.uuidString]
                )
            }
            let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
            if focus {
                v2MaybeFocusWindow(for: tabManager)
                v2MaybeSelectWorkspace(tabManager, workspace: workspace)
            }
            guard let panel = tabManager.attachRemoteCmuxTUI(
                contextID: contextID,
                sessionName: sessionName,
                workspaceID: workspace.id,
                focus: focus
            ) else {
                return .err(
                    code: "surface_create_failed",
                    message: String(
                        localized: "socket.sidebar.machine.attachFailed",
                        defaultValue: "Unable to attach the remote cmux TUI."
                    ),
                    data: ["context_id": contextID]
                )
            }
            return .ok([
                "context_id": contextID,
                "session": sessionName,
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "surface_id": panel.id.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                "tab_ref": v2TabRef(uuid: panel.id),
            ])
        }
    }

#if DEBUG
    /// Introspects live sidebar-column state: persisted modes plus each
    /// mounted AppKit table's applied mode, cell classes, widths, and scroll
    /// origin. Debug builds only; exists to make column-mode plumbing
    /// diagnosable over the socket.
    nonisolated func v2DebugSidebarColumnState(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let tabManager = v2CustomSidebarTabManager(params: params),
                  let context = AppDelegate.shared?.mainWindowContext(for: tabManager)
            else {
                return .err(
                    code: "tab_manager_unavailable",
                    message: String(
                        localized: "socket.sidebar.context.noWindow",
                        defaultValue: "Unable to access the target window."
                    ),
                    data: nil
                )
            }
            let tables = SidebarWorkspaceTableController.debugInstances.allObjects
            let layouts = SidebarLayoutModel.debugInstances.allObjects
            return .ok([
                "boundary_style": SidebarBoundaryStyleStore.shared.style.rawValue,
                "layouts": layouts.map { $0.debugState() },
                "persisted_leading_mode": context.sidebarState.persistedLeadingColumnMode.rawValue,
                "persisted_primary_mode": context.sidebarState.persistedPrimaryColumnMode.rawValue,
                "persisted_width": Double(context.sidebarState.persistedWidth),
                "persisted_leading_width": Double(context.sidebarState.persistedLeadingColumnWidth),
                "tables": tables.map { $0.debugColumnState() },
            ])
        }
    }
#endif

#if DEBUG
    /// Debug-only: switches the sidebar boundary style (same store as the
    /// Debug menu picker) so variants can be screenshotted over the socket.
    nonisolated func v2DebugSidebarBoundaryStyle(params: [String: Any]) -> V2CallResult {
        let requestedStyle: SidebarBoundaryStyle?
        if let raw = params["style"] as? String {
            guard let style = SidebarBoundaryStyle(rawValue: raw) else {
                return .err(
                    code: "invalid_params",
                    message: "style must be one of: "
                        + SidebarBoundaryStyle.allCases.map(\.rawValue).joined(separator: ", "),
                    data: nil
                )
            }
            requestedStyle = style
        } else {
            requestedStyle = nil
        }
        let openWindow = params["open_window"] as? Bool ?? false
        return v2MainSync {
            if let requestedStyle {
                SidebarBoundaryStyleStore.shared.style = requestedStyle
            }
            if openWindow {
                SidebarBoundaryDebugWindowController.shared.show()
            }
            return .ok([
                "style": SidebarBoundaryStyleStore.shared.style.rawValue,
                "window_open": openWindow,
            ])
        }
    }
#endif

    /// Debug/dogfood control for the Finder-style sidebar columns: flips one
    /// column between regular rows and the icon rail, same path as the
    /// divider snap (persisted mode drives the animated layout change).
    nonisolated func v2SidebarColumnSetMode(params: [String: Any]) -> V2CallResult {
        let validColumns = ["machines", "workspaces"]
        guard let column = params["column"] as? String, validColumns.contains(column) else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.column.invalidColumn",
                    defaultValue: "column must be machines or workspaces."
                ),
                data: nil
            )
        }
        guard let rawMode = params["mode"] as? String,
              let mode = SidebarColumnDisplayMode(rawValue: rawMode)
        else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.column.invalidMode",
                    defaultValue: "mode must be regular or icons."
                ),
                data: nil
            )
        }
        return v2MainSync {
            guard let tabManager = v2CustomSidebarTabManager(params: params),
                  let context = AppDelegate.shared?.mainWindowContext(for: tabManager)
            else {
                return .err(
                    code: "tab_manager_unavailable",
                    message: String(
                        localized: "socket.sidebar.context.noWindow",
                        defaultValue: "Unable to access the target window."
                    ),
                    data: nil
                )
            }
            if column == "machines" {
                context.sidebarState.persistedLeadingColumnMode = mode
            } else {
                context.sidebarState.persistedPrimaryColumnMode = mode
            }
            return .ok(["column": column, "mode": mode.rawValue])
        }
    }

    nonisolated func v2SidebarCreationContextSelect(params: [String: Any]) -> V2CallResult {
        guard let rawID = params["context_id"] as? String else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.context.missingId",
                    defaultValue: "context_id is required."
                ),
                data: nil
            )
        }
        let contextID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contextID.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.context.missingId",
                    defaultValue: "context_id is required."
                ),
                data: nil
            )
        }
        return v2MainSync {
            guard let tabManager = v2CustomSidebarTabManager(params: params) else {
                return .err(
                    code: "tab_manager_unavailable",
                    message: String(
                        localized: "socket.sidebar.context.noWindow",
                        defaultValue: "Unable to access the target window."
                    ),
                    data: nil
                )
            }
            guard tabManager.selectSidebarCreationContext(id: contextID) else {
                return .err(
                    code: "not_found",
                    message: String(
                        localized: "socket.sidebar.context.notFound",
                        defaultValue: "Creation context not found."
                    ),
                    data: ["context_id": contextID]
                )
            }
            return .ok(v2SidebarCreationContextPayload(tabManager: tabManager))
        }
    }

    nonisolated func v2SidebarCreationContextReorder(params: [String: Any]) -> V2CallResult {
        guard let rawID = params["context_id"] as? String else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.context.missingId",
                    defaultValue: "context_id is required."
                ),
                data: nil
            )
        }
        let contextID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contextID.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.context.missingId",
                    defaultValue: "context_id is required."
                ),
                data: nil
            )
        }
        guard let index = v2Int(params, "index"), index >= 0 else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.context.invalidIndex",
                    defaultValue: "index must be a non-negative integer."
                ),
                data: nil
            )
        }
        return v2MainSync {
            guard let tabManager = v2CustomSidebarTabManager(params: params) else {
                return .err(
                    code: "tab_manager_unavailable",
                    message: String(
                        localized: "socket.sidebar.context.noWindow",
                        defaultValue: "Unable to access the target window."
                    ),
                    data: nil
                )
            }
            guard contextID != SidebarCreationContextSelection.automaticID,
                  tabManager.reorderSidebarMachineCreationContext(id: contextID, toIndex: index)
            else {
                return .err(
                    code: "not_found",
                    message: String(
                        localized: "socket.sidebar.context.notFound",
                        defaultValue: "Creation context not found."
                    ),
                    data: ["context_id": contextID]
                )
            }
            return .ok(v2SidebarCreationContextPayload(tabManager: tabManager))
        }
    }

    nonisolated func v2SidebarWorkspaceMoveToContext(params: [String: Any]) -> V2CallResult {
        guard let workspaceID = v2UUID(params, "workspace_id") else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.custom.openInvalidWorkspaceId",
                    defaultValue: "Missing or invalid workspace_id"
                ),
                data: nil
            )
        }
        guard let rawContextID = params["context_id"] as? String,
              !rawContextID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.context.missingId",
                    defaultValue: "context_id is required."
                ),
                data: nil
            )
        }
        let contextID = rawContextID.trimmingCharacters(in: .whitespacesAndNewlines)
        return v2MainSync {
            guard let tabManager = v2CustomSidebarTabManager(params: params),
                  tabManager.tabs.contains(where: { $0.id == workspaceID })
            else {
                return .err(
                    code: "workspace_not_found",
                    message: String(
                        localized: "socket.sidebar.custom.openNoWorkspace",
                        defaultValue: "Workspace not found."
                    ),
                    data: ["workspace_id": workspaceID.uuidString]
                )
            }
            guard tabManager.moveSidebarWorkspaces(
                [workspaceID],
                toCreationContextID: contextID
            ) else {
                return .err(
                    code: "not_found",
                    message: String(
                        localized: "socket.sidebar.context.notFound",
                        defaultValue: "Creation context not found."
                    ),
                    data: ["context_id": contextID]
                )
            }
            var payload = v2SidebarCreationContextPayload(tabManager: tabManager)
            payload["moved_workspace_id"] = workspaceID.uuidString
            payload["destination_context_id"] = contextID
            return .ok(payload)
        }
    }

    private nonisolated func v2CustomSidebarName(params: [String: Any]) -> String? {
        guard let raw = params["name"] as? String else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func v2CustomSidebarTabManager(params: [String: Any]) -> TabManager? {
        if let windowId = v2UUID(params, "window_id") {
            return AppDelegate.shared?.tabManagerFor(windowId: windowId)
        }
        if let workspaceId = v2UUID(params, "workspace_id") {
            return AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
        }
        return tabManager ?? AppDelegate.shared?.currentScriptableMainWindow()?.tabManager
    }

    private func v2SidebarCreationContextPayload(tabManager: TabManager) -> [String: Any] {
        [
            "selected_context_id": tabManager.selectedSidebarCreationContextID,
            "contexts": tabManager.sidebarCreationContextSnapshots().map { context in
                [
                    "id": context.id,
                    "title": context.title,
                    "subtitle": context.subtitle,
                    "system_image": context.systemImageName,
                    "selected": context.isSelected,
                    "kind": context.kind.rawValue,
                    "workspace_count": context.workspaceCount,
                    "workspace_ids": context.workspaceIDs.map(\.uuidString),
                    "focused_workspace_id": context.focusedWorkspaceID?.uuidString ?? NSNull(),
                    "capabilities": context.capabilities.map(\.rawValue).sorted(),
                    "connection_state": context.connectionState?.rawValue ?? NSNull(),
                    "child_column": [
                        "id": context.childColumn.id,
                        "renderer_id": context.childColumn.rendererID,
                    ],
                ] as [String: Any]
            },
        ]
    }

    private nonisolated func v2CustomSidebarValidationReport(name: String?) -> CustomSidebarValidationReport {
        CustomSidebarValidator().validate(directory: CmuxExtensionSidebarSelection.customSidebarsDirectory, name: name)
    }

    private nonisolated func v2CustomSidebarReportPayload(_ report: CustomSidebarValidationReport) -> [String: Any] {
        [
            "directory": CmuxExtensionSidebarSelection.customSidebarsDirectory.path,
            "valid_count": report.validCount,
            "error_count": report.errorCount,
            "sidebars": report.entries.map { entry in
                [
                    "name": entry.name,
                    "path": entry.fileURL.path,
                    "kind": entry.kind.rawValue,
                    "ok": entry.isValid,
                    "error": v2OrNull(entry.errorMessage)
                ] as [String: Any]
            }
        ]
    }
}
