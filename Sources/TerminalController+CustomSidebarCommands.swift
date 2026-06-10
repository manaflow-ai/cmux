import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - Custom and right sidebar commands
extension TerminalController {
    nonisolated func v2CustomSidebarValidate(params: [String: Any]) -> V2CallResult {
        let name = v2CustomSidebarName(params: params)
        if let name, name.isEmpty {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.sidebar.custom.invalidName",
                    defaultValue: "Sidebar name must not be empty."
                ),
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
                message: String(
                    localized: "socket.sidebar.custom.invalidName",
                    defaultValue: "Sidebar name must not be empty."
                ),
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
                message: String(
                    localized: "socket.sidebar.custom.selectMissingName",
                    defaultValue: "Select requires a sidebar name."
                ),
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

    private nonisolated func v2CustomSidebarName(params: [String: Any]) -> String? {
        guard let raw = params["name"] as? String else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated func v2CustomSidebarValidationReport(name: String?) -> CustomSidebarValidationReport {
        let directory = CmuxExtensionSidebarSelection.customSidebarsDirectory
        return CustomSidebarValidator().validate(directory: directory, name: name)
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

    func v2ExtensionSidebarSnapshot(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let snapshot = v2MainSync {
            let sequence = max(0, CmuxEventBus.shared.latestSequence)
            let selectedWorkspaceId = tabManager.selectedTabId
            let workspaces = tabManager.tabs.enumerated().map { index, workspace in
                v2ExtensionSidebarWorkspacePayload(
                    workspace: workspace,
                    index: index,
                    selected: workspace.id == tabManager.selectedTabId,
                    rootPath: v2ExtensionSidebarRootPath(for: workspace),
                    projectRootPath: workspace.extensionSidebarProjectRootPath
                )
            }
            return (
                sequence: sequence,
                windowId: AppDelegate.shared?.windowId(for: tabManager),
                selectedWorkspaceId: selectedWorkspaceId,
                workspaces: workspaces
            )
        }

        return .ok([
            "seq": snapshot.sequence,
            "sequence": snapshot.sequence,
            "window_id": v2OrNull(snapshot.windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: snapshot.windowId),
            "selected_workspace_id": v2OrNull(snapshot.selectedWorkspaceId?.uuidString),
            "selected_workspace_ref": v2Ref(kind: .workspace, uuid: snapshot.selectedWorkspaceId),
            "workspaces": snapshot.workspaces
        ])
    }

    @MainActor
    private func v2ExtensionSidebarWorkspacePayload(
        workspace: Workspace,
        index: Int,
        selected: Bool,
        rootPath: String?,
        projectRootPath: String?
    ) -> [String: Any] {
        let latestNotificationText = TerminalNotificationStore.shared.latestNotification(forTabId: workspace.id).flatMap {
            let text = $0.body.isEmpty ? $0.title : $0.body
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return [
            "id": workspace.id.uuidString,
            "ref": v2Ref(kind: .workspace, uuid: workspace.id),
            "index": index,
            "title": workspace.title,
            "description": v2OrNull(workspace.customDescription),
            "selected": selected,
            "pinned": workspace.isPinned,
            "root_path": v2OrNull(rootPath),
            "project_root_path": v2OrNull(projectRootPath),
            "branch_summary": v2OrNull(workspace.gitBranch?.branch),
            "remote_display_target": v2OrNull(workspace.remoteDisplayTarget),
            "remote_connection_state": workspace.remoteConnectionState.rawValue,
            "remote": workspace.remoteStatusPayload(),
            "current_directory": v2OrNull(workspace.currentDirectory),
            "custom_color": v2OrNull(workspace.customColor),
            "unread_count": TerminalNotificationStore.shared.unreadCount(forTabId: workspace.id),
            "latest_notification_text": v2OrNull(latestNotificationText),
            "latest_conversation_message": v2OrNull(workspace.latestConversationMessage),
            "latest_submitted_message": v2OrNull(workspace.latestSubmittedMessage),
            "latest_submitted_at": v2OrNull(workspace.latestSubmittedAt.map(CmuxEventBus.isoTimestamp)),
            "listening_ports": workspace.listeningPorts,
            "pull_request_urls": workspace.sidebarPullRequestsInDisplayOrder().map { $0.url.absoluteString },
            "panel_directories": workspace.sidebarDirectoriesInDisplayOrder(),
            "git_branches": workspace.sidebarGitBranchesInDisplayOrder().map { branch in
                [
                    "branch": branch.branch,
                    "dirty": branch.isDirty
                ] as [String: Any]
            }
        ]
    }

    private func v2ExtensionSidebarRootPath(for workspace: Workspace) -> String? {
        let trimmed = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func sidebarState(_ args: String) -> String {
        var result = ""
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }

            var lines: [String] = []
            lines.append("tab=\(tab.id.uuidString)")
            lines.append("color=\(tab.customColor ?? "none")")
            lines.append("cwd=\(tab.currentDirectory)")

            if let focused = tab.focusedPanelId,
               let focusedDir = tab.panelDirectories[focused] {
                lines.append("focused_cwd=\(focusedDir)")
                lines.append("focused_panel=\(focused.uuidString)")
            } else {
                lines.append("focused_cwd=unknown")
                lines.append("focused_panel=unknown")
            }

            if let git = tab.gitBranch {
                lines.append("git_branch=\(git.branch)\(git.isDirty ? " dirty" : " clean")")
            } else {
                lines.append("git_branch=none")
            }

            if let pr = tab.sidebarPullRequestsInDisplayOrder().first {
                lines.append("pr=#\(pr.number) \(pr.status.rawValue) \(pr.url.absoluteString)")
                lines.append("pr_label=\(pr.label)")
            } else {
                lines.append("pr=none")
                lines.append("pr_label=none")
            }

            if tab.listeningPorts.isEmpty {
                lines.append("ports=none")
            } else {
                lines.append("ports=\(tab.listeningPorts.map(String.init).joined(separator: ","))")
            }

            if let progress = tab.progress {
                let label = progress.label ?? ""
                lines.append("progress=\(String(format: "%.2f", progress.value)) \(label)".trimmingCharacters(in: .whitespaces))
            } else {
                lines.append("progress=none")
            }

            let statusEntries = tab.sidebarStatusEntriesInDisplayOrder()
            lines.append("status_count=\(statusEntries.count)")
            for entry in statusEntries {
                lines.append("  \(sidebarMetadataLine(entry))")
            }

            let metadataBlocks = tab.sidebarMetadataBlocksInDisplayOrder()
            lines.append("meta_block_count=\(metadataBlocks.count)")
            for block in metadataBlocks {
                lines.append("  \(sidebarMetadataBlockLine(block))")
            }

            lines.append("log_count=\(tab.logEntries.count)")
            for entry in tab.logEntries.suffix(5) {
                lines.append("  [\(entry.level.rawValue)] \(entry.message)")
            }

            result = lines.joined(separator: "\n")
        }
        return result
    }

    func rightSidebar(_ args: String) -> String {
        let parsed = RightSidebarRemoteRequest.parse(tokens: Self.tokenizeArgs(args))
        let request: RightSidebarRemoteRequest
        switch parsed {
        case .success(let value):
            request = value
        case .failure(let error):
            return error.message
        }

        return v2MainSync {
            guard let app = AppDelegate.shared else {
                return String(localized: "rightSidebar.remote.error.appDelegateUnavailable", defaultValue: "ERROR: App delegate not available")
            }
            switch app.applyRightSidebarRemoteCommand(request.command, target: request.target) {
            case .ok:
                return "OK"
            case .state(let state):
                return v2Encode([
                    "visible": state.visible,
                    "mode": state.mode.rawValue
                ])
            case .failure(let message):
                return message
            }
        }
    }

#if DEBUG
    func parseRightSidebarRemoteRequestForTesting(_ commandLine: String) -> Result<RightSidebarRemoteRequest, RightSidebarRemoteParseError> {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first?.lowercased() == "right_sidebar" else {
            return .failure(.init(message: "ERROR: Usage: right_sidebar <toggle|show|hide|focus|set|mode>"))
        }
        return RightSidebarRemoteRequest.parse(tokens: Self.tokenizeArgs(parts.count > 1 ? parts[1] : ""))
    }

    func rightSidebarCommandAllowsInAppFocusMutationsForTesting(_ commandLine: String) -> Bool {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first?.lowercased() == "right_sidebar" else { return false }
        return Self.rightSidebarCommandAllowsInAppFocusMutations(args: parts.count > 1 ? parts[1] : "")
    }
#endif

    func resetSidebar(_ args: String) -> String {
        var result = "OK"
        v2MainSync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            tab.resetSidebarContext(reason: "reset_sidebar")
        }
        return result
    }

}
