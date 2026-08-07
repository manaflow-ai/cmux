import Foundation

extension TerminalController {
    nonisolated static var agentPromptComposerBusyMessage: String {
        String(
            localized: "socket.workspace.agentSubmit.composerBusy",
            defaultValue: "The agent composer may contain human input. It was left unchanged; retry after the human submits it or the agent restarts."
        )
    }

    nonisolated static var agentPromptScopeUnavailableMessage: String {
        String(
            localized: "socket.workspace.agentSubmit.scopeUnavailable",
            defaultValue: "The agent terminal is not ready for automation yet. Retry when the agent terminal is ready."
        )
    }

    /// Worker-lane handler for `workspace.agent_submit`.
    ///
    /// The socket worker owns the definitive reply. `v2MainSync` serializes
    /// complete, non-suspending terminal transactions in main-queue arrival
    /// order, so concurrent callers cannot interleave prompt bytes.
    nonisolated func v2WorkspaceAgentSubmit(params: [String: Any]) -> V2CallResult {
        guard let rawWorkspaceID = params["workspace_id"] as? String,
              let workspaceID = UUID(
                uuidString: rawWorkspaceID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
              ) else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.workspace.agentSubmit.invalidWorkspace",
                    defaultValue: "Missing or invalid workspace_id."
                ),
                data: nil
            )
        }
        guard let text = params["text"] as? String,
              !text.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.workspace.agentSubmit.missingText",
                    defaultValue: "Agent prompt text must not be empty."
                ),
                data: nil
            )
        }

        let requestedSurfaceID: UUID?
        if let rawSurface = params["surface_id"], !(rawSurface is NSNull) {
            guard let rawSurface = rawSurface as? String,
                  let parsed = UUID(
                    uuidString: rawSurface.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                  ) else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "socket.workspace.agentSubmit.invalidSurface",
                        defaultValue: "surface_id must be a valid surface UUID."
                    ),
                    data: nil
                )
            }
            requestedSurfaceID = parsed
        } else {
            requestedSurfaceID = nil
        }

        let result = v2MainSync {
            deliverAgentPromptSubmission(
                workspaceID: workspaceID,
                requestedSurfaceID: requestedSurfaceID,
                text: text
            )
        }
        return Self.agentPromptSocketResult(result)
    }

    nonisolated static func agentPromptSocketResult(
        _ result: AgentPromptSubmissionResult
    ) -> V2CallResult {
        switch result {
        case .submitted(let workspaceID, let surfaceID, let queued):
            return .ok([
                "submitted": true,
                "queued": queued,
                "workspace_id": workspaceID.uuidString,
                "surface_id": surfaceID.uuidString,
            ])
        case .rejectedComposerBusy(let workspaceID, let surfaceID):
            return .err(
                code: "rejected_composer_busy",
                message: agentPromptComposerBusyMessage,
                data: [
                    "workspace_id": workspaceID.uuidString,
                    "surface_id": surfaceID.uuidString,
                    "retryable": true,
                    "retry_after":
                        "human_prompt_submit_or_agent_restart",
                ]
            )
        case .agentScopeUnavailable(let workspaceID, let surfaceID):
            return .err(
                code: "agent_scope_unavailable",
                message: agentPromptScopeUnavailableMessage,
                data: [
                    "workspace_id": workspaceID.uuidString,
                    "surface_id": surfaceID.uuidString,
                    "retryable": true,
                    "retry_after": "agent_terminal_ready",
                ]
            )
        case .workspaceNotFound(let workspaceID):
            return .err(
                code: "not_found",
                message: String(
                    localized: "socket.workspace.agentSubmit.workspaceNotFound",
                    defaultValue: "Workspace not found."
                ),
                data: ["workspace_id": workspaceID.uuidString]
            )
        case .surfaceNotFound(let workspaceID, let surfaceID):
            return .err(
                code: "not_found",
                message: String(
                    localized: "socket.workspace.agentSubmit.surfaceNotFound",
                    defaultValue: "Terminal surface not found in that workspace."
                ),
                data: [
                    "workspace_id": workspaceID.uuidString,
                    "surface_id": surfaceID.uuidString,
                ]
            )
        case .agentNotFound(let workspaceID, let requestedSurfaceID):
            var data: [String: Any] = [
                "workspace_id": workspaceID.uuidString,
            ]
            if let requestedSurfaceID {
                data["surface_id"] = requestedSurfaceID.uuidString
            }
            return .err(
                code: "agent_not_found",
                message: String(
                    localized: "socket.workspace.agentSubmit.agentNotFound",
                    defaultValue: "No running agent terminal was found in that workspace."
                ),
                data: data
            )
        case .ambiguousAgent(let workspaceID, let surfaceIDs):
            return .err(
                code: "ambiguous_agent",
                message: String(
                    localized: "socket.workspace.agentSubmit.ambiguousAgent",
                    defaultValue: "More than one agent terminal is available. Specify surface_id."
                ),
                data: [
                    "workspace_id": workspaceID.uuidString,
                    "surface_ids": surfaceIDs.map(\.uuidString),
                ]
            )
        case .inputQueueFull(let workspaceID, let surfaceID):
            return .err(
                code: "input_queue_full",
                message: terminalInputQueueFullMessage,
                data: [
                    "workspace_id": workspaceID.uuidString,
                    "surface_id": surfaceID.uuidString,
                ]
            )
        case .surfaceUnavailable(let workspaceID, let surfaceID):
            return .err(
                code: "surface_unavailable",
                message: terminalSurfaceUnavailableMessage,
                data: [
                    "workspace_id": workspaceID.uuidString,
                    "surface_id": surfaceID.uuidString,
                ]
            )
        case .processExited(let workspaceID, let surfaceID):
            return .err(
                code: "process_exited",
                message: terminalProcessExitedMessage,
                data: [
                    "workspace_id": workspaceID.uuidString,
                    "surface_id": surfaceID.uuidString,
                ]
            )
        case .invalidSubmitKey(let workspaceID, let surfaceID):
            return .err(
                code: "internal_error",
                message: String(
                    localized: "socket.workspace.agentSubmit.invalidSubmitKey",
                    defaultValue: "The agent terminal cannot accept this prompt. Restart the agent and retry."
                ),
                data: [
                    "workspace_id": workspaceID.uuidString,
                    "surface_id": surfaceID.uuidString,
                ]
            )
        }
    }
}
