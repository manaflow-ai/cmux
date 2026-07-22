import CMUXAgentLaunch
import CmuxTerminal
import Foundation

extension TerminalController {
    /// Clears the agent TUI's current prompt through the same line-editor path
    /// used by mobile chat before a composed prompt is pasted.
    func clearAgentPrompt(_ terminalPanel: TerminalPanel) -> TerminalSurface.NamedKeySendResult {
        var latestAccepted: TerminalSurface.NamedKeySendResult = .sent
        for keyName in ["ctrl+a", "ctrl+k", "ctrl+u"] {
            let result = terminalPanel.sendNamedKeyResult(keyName)
            guard result.accepted else { return result }
            latestAccepted = result
        }
        return latestAccepted
    }

    /// Handles cmux-composed agent launches into an existing terminal surface.
    ///
    /// Phone launch composers must set `launch_intent` and a client-minted `ticket_id`;
    /// raw composer text must omit `launch_intent` so it follows the ordinary paste path.
    func handleCmuxOwnedMobileAgentInput(
        params: [String: Any],
        text: String,
        surfaceID: UUID,
        workspaceID: UUID,
        terminalPanel: TerminalPanel
    ) -> V2CallResult? {
        guard v2HasNonNullParam(params, "launch_intent") else { return nil }
        guard let appDelegate = AppDelegate.shared else { return nil }

        let ticketID: UUID?
        if v2HasNonNullParam(params, "ticket_id") {
            guard let rawTicketID = v2String(params, "ticket_id"),
                  let parsedTicketID = UUID(uuidString: rawTicketID) else {
                return invalidMobileAgentLaunchInput(field: "ticket_id")
            }
            ticketID = parsedTicketID
        } else {
            ticketID = nil
        }

        let intent: AgentLaunchIntent
        switch v2String(params, "launch_intent")?.lowercased() {
        case "launch_only":
            intent = .launchOnly
        case "launch_then_submit_prompt":
            guard let prompt = v2RawString(params, "prompt"), !prompt.isEmpty else {
                return invalidMobileAgentLaunchInput(field: "prompt")
            }
            intent = .launchThenSubmitPrompt(prompt, ticketID: ticketID)
        default:
            return invalidMobileAgentLaunchInput(field: "launch_intent")
        }

        switch appDelegate.agentLaunchGuard.perform(
            surfaceID: surfaceID.uuidString,
            command: text,
            intent: intent
        ) {
        case .launched:
            return .ok(mobileAgentInputPayload(
                workspaceID: workspaceID,
                terminalPanel: terminalPanel,
                fields: ["agent_launch": "launched"]
            ))
        case .suppressed(let reason):
            let reasonCode = reason == .agentAlreadyRunning
                ? "agent_already_running"
                : "launch_already_pending"
            NSLog(
                "[AgentLaunch] suppressed mobile launch for surface %@: %@",
                surfaceID.uuidString,
                reasonCode
            )
            return .ok(mobileAgentInputPayload(
                workspaceID: workspaceID,
                terminalPanel: terminalPanel,
                submitted: false,
                fields: ["launch_suppressed": reasonCode]
            ))
        case .promptRerouted(let queued):
            return .ok(mobileAgentInputPayload(
                workspaceID: workspaceID,
                terminalPanel: terminalPanel,
                fields: ["queued": queued, "agent_prompt_rerouted": true]
            ))
        case .failed(let code):
            return mobileAgentInputError(code: code, surfaceID: surfaceID)
        }
    }

    private func mobileAgentInputPayload(
        workspaceID: UUID,
        terminalPanel: TerminalPanel,
        submitted: Bool = true,
        fields: [String: Any]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "workspace_id": workspaceID.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "submitted": submitted,
        ]
        fields.forEach { payload[$0.key] = $0.value }
        return payload
    }

    private func mobileAgentInputError(code: String, surfaceID: UUID) -> V2CallResult {
        .err(
            code: code,
            message: Self.terminalSurfaceUnavailableMessage,
            data: ["surface_id": surfaceID.uuidString]
        )
    }

    private func invalidMobileAgentLaunchInput(field: String) -> V2CallResult {
        .err(
            code: "invalid_params",
            message: String(
                localized: "mobile.terminalPaste.invalidAgentLaunchParameters",
                defaultValue: "Invalid agent launch parameters"
            ),
            data: ["field": field]
        )
    }
}
