import Foundation

extension TerminalController {
    /// Return the current Mac focus target for mobile Voice Mode.
    @MainActor
    func v2MobileFocusGet(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .ok(MobileFocusSnapshotPayload(
                workspaceID: nil,
                workspaceTitle: nil,
                surfaceID: nil,
                surfaceTitle: nil,
                surfaceType: nil,
                isTerminal: false
            ).jsonObject())
        }
        return .ok(MobileFocusSnapshotPayload.snapshot(tabManager: tabManager).jsonObject())
    }

    /// Insert Voice Mode text into the Mac's currently focused terminal.
    @MainActor
    func v2MobileVoiceInput(params: [String: Any]) -> V2CallResult {
        guard let text = v2RawString(params, "text"), !text.isEmpty else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
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

        let submit = (params["submit"] as? Bool) ?? false
        let payload = submit ? text + "\r" : text
        let sendResult = terminalPanel.surface.sendInputResult(payload)
        switch sendResult {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "mobileHost.voiceInput")
        case .queued:
            break
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: ["surface_id": focusedPanelID.uuidString])
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: ["surface_id": focusedPanelID.uuidString])
        case .processExited:
            return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: ["surface_id": focusedPanelID.uuidString])
        }

        return .ok([
            "workspace_id": workspace.id.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "surface_title": workspace.panelTitle(panelId: terminalPanel.id) ?? terminalPanel.displayTitle,
            "queued": sendResult == .queued,
        ])
    }
}
