internal import Foundation

/// The small system-domain bodies: `auth.login`, `session.restore_previous`,
/// `settings.open`, `feedback.open`, `extension.sidebar.snapshot`, the
/// `surface.split_off` / `surface.drag_to_split` bridge, and the DEBUG-only
/// `mobile.dev_stack_auth.configure`.
extension ControlCommandCoordinator {
    /// `auth.login` — the main-actor login acknowledgement (always ok; the
    /// password handshake itself happens before dispatch).
    func authLogin() -> ControlCallResult {
        .ok(.object([
            "authenticated": .bool(true),
            "required": .bool(systemContext?.controlAuthPasswordRequired() ?? false),
        ]))
    }

    /// `session.restore_previous` — reopen the previous session snapshot.
    func sessionRestorePrevious() -> ControlCallResult {
        switch systemContext?.controlSessionRestorePrevious() {
        case .restored:
            return .ok(.object(["restored": .bool(true)]))
        case .noSnapshot(let message):
            return .err(code: "not_found", message: message, data: nil)
        case nil:
            return .err(code: "not_found", message: "No previous session snapshot available", data: nil)
        }
    }

    /// `settings.open` — open the settings window, optionally at a target pane.
    func settingsOpen(_ params: [String: JSONValue]) -> ControlCallResult {
        let targetRaw = string(params, "target")
        let requestedActivate = bool(params, "activate") ?? true
        guard let systemContext else {
            // Fail closed: without the app context no window can have been
            // presented, and `opened` must mean a window actually exists
            // (https://github.com/manaflow-ai/cmux/issues/7775).
            return .err(code: "unavailable", message: "Settings context not attached", data: nil)
        }
        let resolution = systemContext.controlSettingsOpen(
            targetRaw: targetRaw,
            requestedActivate: requestedActivate
        )
        switch resolution {
        case .invalidTarget:
            return .err(
                code: "invalid_params",
                message: "Unknown settings target",
                data: .object(["target": orNull(targetRaw)])
            )
        case .opened(let target):
            return .ok(.object([
                "opened": .bool(true),
                "target": .string(target),
            ]))
        case .failed(let message):
            return .err(
                code: "unavailable",
                message: message,
                data: .object(["target": orNull(targetRaw)])
            )
        }
    }

    /// `feedback.open` — open the feedback composer (always ok).
    func feedbackOpen(_ params: [String: JSONValue]) -> ControlCallResult {
        systemContext?.controlFeedbackOpen(
            workspaceID: uuid(params, "workspace_id"),
            windowID: uuid(params, "window_id"),
            requestedActivate: bool(params, "activate") ?? false
        )
        return .ok(.object(["opened": .bool(true)]))
    }

    /// `extension.sidebar.snapshot` — the sidebar extension's workspace feed.
    func extensionSidebarSnapshot(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let snapshot = systemContext?.controlExtensionSidebarSnapshot(routing: routingSelectors(params)) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return .ok(.object([
            "seq": .int(Int64(snapshot.sequence)),
            "sequence": .int(Int64(snapshot.sequence)),
            "window_id": orNull(snapshot.windowID?.uuidString),
            "window_ref": ref(.window, snapshot.windowID),
            "selected_workspace_id": orNull(snapshot.selectedWorkspaceID?.uuidString),
            "selected_workspace_ref": ref(.workspace, snapshot.selectedWorkspaceID),
            "workspaces": .array(snapshot.workspaces.map(extensionSidebarWorkspacePayload)),
        ]))
    }

    /// One workspace row of the sidebar snapshot (the legacy
    /// `v2ExtensionSidebarWorkspacePayload`).
    private func extensionSidebarWorkspacePayload(_ workspace: ControlExtensionSidebarWorkspace) -> JSONValue {
        .object([
            "id": .string(workspace.workspaceID.uuidString),
            "ref": ref(.workspace, workspace.workspaceID),
            "index": .int(Int64(workspace.index)),
            "title": .string(workspace.title),
            "description": orNull(workspace.description),
            "selected": .bool(workspace.isSelected),
            "pinned": .bool(workspace.isPinned),
            "root_path": orNull(workspace.rootPath),
            "project_root_path": orNull(workspace.projectRootPath),
            "branch_summary": orNull(workspace.branchSummary),
            "remote_display_target": orNull(workspace.remoteDisplayTarget),
            "remote_connection_state": .string(workspace.remoteConnectionStateRawValue),
            "remote": workspace.remotePayload,
            "current_directory": .string(workspace.currentDirectory),
            "custom_color": orNull(workspace.customColor),
            "unread_count": .int(Int64(workspace.unreadCount)),
            "latest_notification_text": orNull(workspace.latestNotificationText),
            "latest_conversation_message": orNull(workspace.latestConversationMessage),
            "latest_submitted_message": orNull(workspace.latestSubmittedMessage),
            "latest_submitted_at": orNull(workspace.latestSubmittedAtISO),
            "listening_ports": .array(workspace.listeningPorts.map { .int(Int64($0)) }),
            "pull_request_urls": .array(workspace.pullRequestURLs.map { .string($0) }),
            "panel_directories": .array(workspace.panelDirectories.map { .string($0) }),
            "git_branches": .array(workspace.gitBranches.map { branch in
                .object([
                    "branch": .string(branch.branch),
                    "dirty": .bool(branch.isDirty),
                ])
            }),
        ])
    }

    /// `surface.split_off` / `surface.drag_to_split` — delegate to the shared
    /// app-side split-off logic (also driven by the v1 `drag_surface_to_split`
    /// command; the app bridges the result byte-faithfully).
    func surfaceSplitOff(_ params: [String: JSONValue]) -> ControlCallResult {
        systemContext?.controlSurfaceSplitOff(params: params)
            ?? .err(code: "unavailable", message: "AppDelegate not available", data: nil)
    }

    /// `workspace.action` — delegate to the shared app-side workspace-action
    /// logic (also driven by the mobile host's gated `workspace.action` RPC,
    /// so the body stays app-side; the app bridges the result byte-faithfully).
    func workspaceAction(_ params: [String: JSONValue]) -> ControlCallResult {
        systemContext?.controlWorkspaceAction(params: params)
            ?? .err(code: "unavailable", message: "TabManager not available", data: nil)
    }

#if DEBUG
    /// `mobile.dev_stack_auth.configure` — DEBUG-only dev Stack auth token
    /// configuration for the mobile host.
    func mobileDevStackAuthConfigure(_ params: [String: JSONValue]) -> ControlCallResult {
        let enabled = bool(params, "enabled")
        let token = optionalTrimmedRawString(params, "token")
        if enabled == false {
            systemContext?.controlMobileDevStackAuthSetToken(nil)
            return .ok(.object(["enabled": .bool(false)]))
        }

        guard let token else {
            return .err(
                code: "invalid_params",
                message: "mobile.dev_stack_auth.configure requires params.token",
                data: nil
            )
        }

        systemContext?.controlMobileDevStackAuthSetToken(token)
        return .ok(.object([
            "enabled": .bool(true),
            "token_prefix": .string(String(token.prefix(8))),
        ]))
    }
#endif
}
