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
            return .ok(v2CustomSidebarReportPayload(report))
        }
        if let errorMessage = entry.errorMessage {
            var payload = v2CustomSidebarReportPayload(report)
            payload["message"] = errorMessage
            return .ok(payload)
        }

        return v2MainSync {
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
            workspace.clearSplitZoom()

            let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? true)
            let panel: CustomSidebarPanel?
            if focus, let focusedPanelId = workspace.focusedPanelId {
                panel = workspace.openOrFocusCustomSidebarSplit(from: focusedPanelId, name: name)
            } else if let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first {
                panel = workspace.openOrFocusCustomSidebarSurface(inPane: paneId, name: name, focus: focus)
            } else {
                panel = nil
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
            payload["surface_ref"] = v2TabRef(uuid: panel.id)
            payload["type"] = PanelType.customSidebar.rawValue
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
