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

    func handleCmuxOwnedMobileAgentInput(
        text: String,
        surfaceID: UUID,
        workspaceID: UUID,
        terminalPanel: TerminalPanel
    ) -> V2CallResult? {
        guard let appDelegate = AppDelegate.shared else { return nil }

        if TextBoxAgentDetection.launchAgentID(from: text) != nil {
            switch appDelegate.agentLaunchGuard.perform(
                surfaceID: surfaceID.uuidString,
                command: text,
                intent: .launchOnly
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

        guard appDelegate.agentSurfaceLaunchStateObserver.agentLaunchState(
            surfaceID: surfaceID.uuidString
        ) == .runningAgent else { return nil }
        switch appDelegate.agentSurfaceLaunchExecutor.submitPrompt(
            surfaceID: surfaceID.uuidString,
            text: text
        ) {
        case .accepted:
            return .ok(mobileAgentInputPayload(
                workspaceID: workspaceID,
                terminalPanel: terminalPanel,
                fields: ["queued": false, "agent_prompt_rerouted": true]
            ))
        case .queued:
            return .ok(mobileAgentInputPayload(
                workspaceID: workspaceID,
                terminalPanel: terminalPanel,
                fields: ["queued": true, "agent_prompt_rerouted": true]
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
}
