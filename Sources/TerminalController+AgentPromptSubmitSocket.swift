import CmuxControlSocket
import CmuxTerminalCore
import Foundation

private struct AgentPromptSubmissionRequest: Sendable {
    let rawWorkspaceID: String
    let rawSurfaceID: String?
    let text: String
}

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

    /// Synchronous compatibility handler for `workspace.agent_submit` callers
    /// that still use the legacy dispatcher. Network socket traffic uses the
    /// async handler below so its lane remains occupied through delivery.
    nonisolated func v2WorkspaceAgentSubmit(params: [String: Any]) -> V2CallResult {
        switch Self.parseAgentPromptSubmissionRequest(params) {
        case .failure(let result):
            return result
        case .success(let request):
            guard agentPromptSubmissionDeliveryLane
                .tryBeginSynchronousTurn() else {
                return Self.agentPromptSocketResult(
                    .laneBusy
                )
            }
            let receipt = PromptSubmissionDeliveryReceipt()
            let outcome = admitAgentPromptSubmissionValue(
                request: request,
                deliveryReceipt: receipt
            )
            let result = Self.agentPromptSocketResult(outcome)
            if case .admitted(.submitted) = outcome {
                agentPromptSubmissionDeliveryLane
                    .holdSynchronousTurn(receipt)
            } else {
                agentPromptSubmissionDeliveryLane
                    .completeSynchronousTurn()
            }
            return result
        }
    }

    /// Async socket-worker handler that keeps one global transaction turn
    /// until the admitted compound prompt is actually delivered.
    nonisolated func v2WorkspaceAgentSubmitAsync(
        request: ControlRequest
    ) async -> String {
        let params = request.params.mapValues(\.foundationObject)
        switch Self.parseAgentPromptSubmissionRequest(params) {
        case .failure(let result):
            return Self.v2Encoder.response(
                id: request.id,
                Self.controlCallResult(fromLegacy: result)
            )
        case .success(let parsed):
            let result = await agentPromptSubmissionDeliveryLane.perform {
                receipt in
                self.admitAgentPromptSubmissionValue(
                    request: parsed,
                    deliveryReceipt: receipt
                )
            }
            let socketResult = Self.agentPromptSocketResult(result)
            return Self.v2Encoder.response(
                id: request.id,
                Self.controlCallResult(fromLegacy: socketResult)
            )
        }
    }

    private nonisolated static func parseAgentPromptSubmissionRequest(
        _ params: [String: Any]
    ) -> Result<AgentPromptSubmissionRequest, V2CallResult> {
        guard let rawWorkspaceID = params["workspace_id"] as? String else {
            return .failure(
                .err(
                    code: "invalid_params",
                    message: String(
                        localized: "socket.workspace.agentSubmit.invalidWorkspace",
                        defaultValue: "Missing or invalid workspace_id."
                    ),
                    data: nil
                )
            )
        }
        guard let text = params["text"] as? String,
              !text.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            return .failure(
                .err(
                    code: "invalid_params",
                    message: String(
                        localized: "socket.workspace.agentSubmit.missingText",
                        defaultValue: "Agent prompt text must not be empty."
                    ),
                    data: nil
                )
            )
        }
        let rawSurfaceID: String?
        if let rawSurface = params["surface_id"], !(rawSurface is NSNull) {
            guard let rawSurface = rawSurface as? String else {
                return .failure(
                    .err(
                        code: "invalid_params",
                        message: String(
                            localized: "socket.workspace.agentSubmit.invalidSurface",
                            defaultValue: "surface_id must be a valid surface UUID."
                        ),
                        data: nil
                    )
                )
            }
            rawSurfaceID = rawSurface
        } else {
            rawSurfaceID = nil
        }
        return .success(
            AgentPromptSubmissionRequest(
                rawWorkspaceID: rawWorkspaceID,
                rawSurfaceID: rawSurfaceID,
                text: text
            )
        )
    }

    private nonisolated func admitAgentPromptSubmissionValue(
        request: AgentPromptSubmissionRequest,
        deliveryReceipt: PromptSubmissionDeliveryReceipt?
    ) -> AgentPromptSubmissionDeliveryLane.Outcome {
        let rawWorkspaceID = request.rawWorkspaceID
        let rawSurfaceID = request.rawSurfaceID
        let text = request.text
        let admit = {
            self.admitAgentPromptSubmission(
                rawWorkspaceID: rawWorkspaceID,
                rawSurfaceID: rawSurfaceID,
                text: text,
                deliveryReceipt: deliveryReceipt
            )
        }
        if Thread.isMainThread {
            return admit()
        }
        return agentPromptSubmissionAdmissionQueue.sync(execute: admit)
    }

    private nonisolated func admitAgentPromptSubmission(
        rawWorkspaceID: String,
        rawSurfaceID: String?,
        text: String,
        deliveryReceipt: PromptSubmissionDeliveryReceipt? = nil
    ) -> AgentPromptSubmissionDeliveryLane.Outcome {
        v2MainSync(commandKey: "workspace.agent_submit") {
            guard let workspaceID = v2UUIDAny(rawWorkspaceID) else {
                return .invalidWorkspace
            }
            let requestedSurfaceID: UUID?
            if let rawSurfaceID {
                guard let parsed = v2UUIDAny(rawSurfaceID) else {
                    return .invalidSurface
                }
                requestedSurfaceID = parsed
            } else {
                requestedSurfaceID = nil
            }
            return .admitted(
                deliverAgentPromptSubmission(
                    workspaceID: workspaceID,
                    requestedSurfaceID: requestedSurfaceID,
                    text: text,
                    deliveryReceipt: deliveryReceipt
                )
            )
        }
    }

    private nonisolated static func agentPromptSocketResult(
        _ outcome: AgentPromptSubmissionDeliveryLane.Outcome
    ) -> V2CallResult {
        switch outcome {
        case .admitted(let result):
            return agentPromptSocketResult(result)
        case .invalidWorkspace:
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.workspace.agentSubmit.invalidWorkspace",
                    defaultValue: "Missing or invalid workspace_id."
                ),
                data: nil
            )
        case .invalidSurface:
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.workspace.agentSubmit.invalidSurface",
                    defaultValue: "surface_id must be a valid surface UUID."
                ),
                data: nil
            )
        case .laneBusy:
            return .err(
                code: "input_queue_full",
                message: terminalInputQueueFullMessage,
                data: ["retryable": true]
            )
        }
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
