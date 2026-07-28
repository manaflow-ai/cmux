import Foundation

extension TerminalController {
    /// Return the current Mac focus target for mobile Voice Mode.
    @MainActor
    func v2MobileFocusGet(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .ok(MobileFocusSnapshotPayload.empty.jsonObject())
        }
        return .ok(MobileFocusSnapshotPayload.snapshot(tabManager: tabManager).jsonObject())
    }

    /// Insert Voice Mode text into an explicit terminal or the current focus.
    @MainActor
    func v2MobileVoiceInput(params: [String: Any]) -> V2CallResult {
        guard let text = v2RawString(params, "text"),
              !text.isEmpty,
              text.utf8.count <= 64 * 1_024 else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }
        let hasExplicitTarget = params["workspace_id"] != nil
            || params["surface_id"] != nil
        if hasExplicitTarget {
            guard let workspaceRaw = v2RawString(params, "workspace_id"),
                  let surfaceRaw = v2RawString(params, "surface_id"),
                  let workspaceID = UUID(uuidString: workspaceRaw),
                  let surfaceID = UUID(uuidString: surfaceRaw),
                  let resolved = mobileResolveWorkspaceAndSurface(
                    params: params,
                    requireTerminal: true
                  ),
                  let resolvedSurfaceID = resolved.surfaceId,
                  resolved.workspace.id == workspaceID,
                  resolvedSurfaceID == surfaceID,
                  let terminalPanel = resolved.workspace.terminalPanel(for: resolvedSurfaceID) else {
                return .err(
                    code: "target_unavailable",
                    message: String(
                        localized: "mobile.voice.input.targetUnavailable",
                        defaultValue: "That terminal is no longer available."
                    ),
                    data: nil
                )
            }
            return v2SendMobileVoiceInput(
                text: text,
                params: params,
                workspace: resolved.workspace,
                terminalPanel: terminalPanel
            )
        }

        guard let tabManager = v2ResolveTabManager(params: params),
              let workspaceID = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }),
              let focusedPanelID = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: focusedPanelID) else {
            return .err(
                code: "no_focused_terminal",
                message: String(
                    localized: "mobile.voice.input.noFocusedTerminal",
                    defaultValue: "Click a terminal pane on your Mac, then try again."
                ),
                data: nil
            )
        }
        if let expectedWorkspaceID = params["expected_workspace_id"] as? String,
           let expectedSurfaceID = params["expected_surface_id"] as? String,
           (expectedWorkspaceID != workspace.id.uuidString || expectedSurfaceID != terminalPanel.id.uuidString) {
            return .err(
                code: "target_changed",
                message: String(
                    localized: "mobile.voice.input.targetChanged",
                    defaultValue: "The focused pane changed. Check the target and speak again."
                ),
                data: [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": terminalPanel.id.uuidString,
                ]
            )
        }

        return v2SendMobileVoiceInput(
            text: text,
            params: params,
            workspace: workspace,
            terminalPanel: terminalPanel
        )
    }

    @MainActor
    private func v2SendMobileVoiceInput(
        text: String,
        params: [String: Any],
        workspace: Workspace,
        terminalPanel: TerminalPanel
    ) -> V2CallResult {
        let submit = (params["submit"] as? Bool) ?? false
        let payload = submit ? text + "\r" : text
        let sendResult = terminalPanel.surface.sendInputResult(payload)
        switch sendResult {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "mobileHost.voiceInput")
        case .queued:
            break
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: ["surface_id": terminalPanel.id.uuidString])
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: ["surface_id": terminalPanel.id.uuidString])
        case .processExited:
            return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: ["surface_id": terminalPanel.id.uuidString])
        }

        return .ok([
            "workspace_id": workspace.id.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "surface_title": workspace.panelTitle(panelId: terminalPanel.id) ?? terminalPanel.displayTitle,
            "queued": sendResult == .queued,
        ])
    }
}
