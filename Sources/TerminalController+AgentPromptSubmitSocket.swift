import Foundation
import CmuxControlSocket
import CmuxTerminalCore

extension TerminalController {
    private enum AgentPromptSubmitParse {
        case success(workspaceID: UUID, surfaceID: UUID?, text: String)
        case failure(V2CallResult)
    }

    nonisolated static var agentPromptComposerBusyMessage: String {
        String(
            localized: "socket.workspace.agentSubmit.composerBusy",
            defaultValue: "The agent composer may contain human input. It was left unchanged; the message is queued until that input is submitted."
        )
    }

    nonisolated static var agentPromptScopeUnavailableMessage: String {
        String(
            localized: "socket.workspace.agentSubmit.scopeUnavailable",
            defaultValue: "The agent terminal is not ready for automation yet. Retry when the agent terminal is ready."
        )
    }

    /// Parses one addressed prompt request without touching workspace state.
    private nonisolated static func parseAgentPromptSubmit(
        params: [String: Any]
    ) -> AgentPromptSubmitParse {
        guard let rawWorkspaceID = params["workspace_id"] as? String,
              let workspaceID = UUID(
                uuidString: rawWorkspaceID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
              ) else {
            return .failure(.err(
                code: "invalid_params",
                message: String(
                    localized: "socket.workspace.agentSubmit.invalidWorkspace",
                    defaultValue: "Missing or invalid workspace_id."
                ),
                data: nil
            ))
        }
        guard let text = params["text"] as? String,
              !text.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            return .failure(.err(
                code: "invalid_params",
                message: String(
                    localized: "socket.workspace.agentSubmit.missingText",
                    defaultValue: "Agent prompt text must not be empty."
                ),
                data: nil
            ))
        }
        guard text.utf8.count <= AgentPromptSubmissionService.maximumPromptBytes else {
            return .failure(.err(
                code: "invalid_params",
                message: String(
                    localized: "socket.workspace.agentSubmit.promptTooLarge",
                    defaultValue: "Agent prompt text is too large; keep it under 1 MiB."
                ),
                data: ["maximum_bytes": AgentPromptSubmissionService.maximumPromptBytes]
            ))
        }

        let surfaceID: UUID?
        if let rawSurface = params["surface_id"], !(rawSurface is NSNull) {
            guard let rawSurface = rawSurface as? String,
                  let parsed = UUID(
                    uuidString: rawSurface.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                  ) else {
                return .failure(.err(
                    code: "invalid_params",
                    message: String(
                        localized: "socket.workspace.agentSubmit.invalidSurface",
                        defaultValue: "surface_id must be a valid surface UUID."
                    ),
                    data: nil
                ))
            }
            surfaceID = parsed
        } else {
            surfaceID = nil
        }
        return .success(workspaceID: workspaceID, surfaceID: surfaceID, text: text)
    }

    /// Enqueues a complete prompt on the main-actor admission owner.
    @MainActor
    private func enqueueAgentPromptSubmission(
        workspaceID: UUID,
        surfaceID: UUID?,
        text: String
    ) -> AgentPromptSubmissionService.Receipt {
        let receipt = agentPromptSubmissionService.submit(
            workspaceID: workspaceID,
            requestedSurfaceID: surfaceID,
            text: text,
            delivery: { [weak self] in
                guard let self else {
                    return .workspaceNotFound(workspaceID: workspaceID)
                }
                return self.deliverAgentPromptSubmission(
                    workspaceID: workspaceID,
                    requestedSurfaceID: surfaceID,
                    text: text
                )
            }
        )
        switch receipt.result {
        case .submitted(let resolvedWorkspaceID, let resolvedSurfaceID, let queued):
            CmuxEventBus.shared.publishAgentPromptDelivery(
                messageID: receipt.messageID,
                workspaceId: resolvedWorkspaceID,
                surfaceId: resolvedSurfaceID,
                state: queued ? "queued" : "accepted"
            )
            if !queued {
                scheduleAgentPromptConfirmationFallback(workspaceID: workspaceID)
            }
        case .queued(let resolvedWorkspaceID, let resolvedSurfaceID, let reason):
            CmuxEventBus.shared.publishAgentPromptDelivery(
                messageID: receipt.messageID,
                workspaceId: resolvedWorkspaceID,
                surfaceId: resolvedSurfaceID,
                state: "queued",
                reason: reason
            )
            if reason == "prior_prompt_in_flight" {
                scheduleAgentPromptConfirmationFallback(workspaceID: workspaceID)
            }
        default:
            break
        }
        return receipt
    }

    /// Guarantees the workspace FIFO advances even when no later hook,
    /// panel, or workspace event triggers a drain. `drain` clears a stale
    /// unconfirmed barrier itself, so the fallback is just a delayed drain.
    @MainActor
    private func scheduleAgentPromptConfirmationFallback(workspaceID: UUID) {
        let timeout = agentPromptSubmissionService.confirmationTimeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(max(0, timeout + 0.5) * 1_000_000_000)
            )
            self?.drainAgentPromptQueue(workspaceID: workspaceID)
        }
    }

    /// Retries queued requests after a hook, shell-idle transition, or agent
    /// scope rebind. The event stream is the durable completion channel for
    /// callers that received a queued message id.
    @MainActor
    func drainAgentPromptQueue(workspaceID: UUID) {
        let receipts = agentPromptSubmissionService.drain(workspaceID: workspaceID)
        var acceptedPrompt = false
        for receipt in receipts {
            switch receipt.result {
            case .submitted(let resolvedWorkspaceID, let surfaceID, let queued):
                if !queued { acceptedPrompt = true }
                CmuxEventBus.shared.publishAgentPromptDelivery(
                    messageID: receipt.messageID,
                    workspaceId: resolvedWorkspaceID,
                    surfaceId: surfaceID,
                    state: queued ? "queued" : "accepted"
                )
            case .queued:
                break
            case .workspaceNotFound(let resolvedWorkspaceID):
                CmuxEventBus.shared.publishAgentPromptDelivery(
                    messageID: receipt.messageID,
                    workspaceId: resolvedWorkspaceID,
                    surfaceId: nil,
                    state: "failed",
                    reason: "workspace_not_found"
                )
            case .surfaceNotFound(let resolvedWorkspaceID, let surfaceID):
                CmuxEventBus.shared.publishAgentPromptDelivery(
                    messageID: receipt.messageID,
                    workspaceId: resolvedWorkspaceID,
                    surfaceId: surfaceID,
                    state: "failed",
                    reason: "surface_not_found"
                )
            default:
                // The initial socket reply already carried validation and
                // transport failures. A queued request reaching one of these
                // terminal outcomes still gets an explicit failure event.
                CmuxEventBus.shared.publishAgentPromptDelivery(
                    messageID: receipt.messageID,
                    workspaceId: workspaceID,
                    surfaceId: nil,
                    state: "failed",
                    reason: "delivery_failed"
                )
            }
        }
        if acceptedPrompt {
            scheduleAgentPromptConfirmationFallback(workspaceID: workspaceID)
        }
    }

    /// Completes queued messages explicitly when their workspace is closed.
    @MainActor
    func discardAgentPromptQueue(workspaceID: UUID) {
        for receipt in agentPromptSubmissionService.remove(workspaceID: workspaceID) {
            CmuxEventBus.shared.publishAgentPromptDelivery(
                messageID: receipt.messageID,
                workspaceId: workspaceID,
                surfaceId: nil,
                state: "failed",
                reason: "workspace_not_found"
            )
        }
    }

    /// Completes messages explicitly bound to a surface that disappeared.
    @MainActor
    func discardAgentPromptQueue(surfaceID: UUID, workspaceID: UUID) {
        for receipt in agentPromptSubmissionService.remove(surfaceID: surfaceID) {
            CmuxEventBus.shared.publishAgentPromptDelivery(
                messageID: receipt.messageID,
                workspaceId: workspaceID,
                surfaceId: surfaceID,
                state: "failed",
                reason: "surface_not_found"
            )
        }
    }

    private nonisolated static func agentPromptHandleNeedsResolution(
        _ raw: String?
    ) -> Bool {
        guard let raw else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && UUID(uuidString: trimmed) == nil
    }

    private nonisolated static func agentPromptParamsApplyingResolvedHandles(
        _ params: [String: Any],
        workspaceID: UUID?,
        surfaceID: UUID?
    ) -> [String: Any] {
        var updated = params
        if let workspaceID { updated["workspace_id"] = workspaceID.uuidString }
        if let surfaceID { updated["surface_id"] = surfaceID.uuidString }
        return updated
    }

    /// Worker-lane handler for `workspace.agent_submit` used by synchronous
    /// in-process callers and the legacy socket path.
    nonisolated func v2WorkspaceAgentSubmit(params: [String: Any]) -> V2CallResult {
        // Accept the same workspace/surface handle refs as other v2 methods
        // by resolving non-UUID handles before the strict parser.
        var requestParams = params
        let rawWorkspace = params["workspace_id"] as? String
        let rawSurface = params["surface_id"] as? String
        if Self.agentPromptHandleNeedsResolution(rawWorkspace)
            || Self.agentPromptHandleNeedsResolution(rawSurface) {
            let resolved = v2MainSync {
                (self.v2UUIDAny(rawWorkspace), self.v2UUIDAny(rawSurface))
            }
            requestParams = Self.agentPromptParamsApplyingResolvedHandles(
                params,
                workspaceID: resolved.0,
                surfaceID: resolved.1
            )
        }
        let parsed = Self.parseAgentPromptSubmit(params: requestParams)
        guard case .success(let workspaceID, let surfaceID, let text) = parsed else {
            guard case .failure(let error) = parsed else {
                return .err(code: "invalid_params", message: "Invalid agent prompt", data: nil)
            }
            return error
        }
        let receipt = v2MainSync {
            enqueueAgentPromptSubmission(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                text: text
            )
        }
        return Self.agentPromptSocketResult(
            receipt.result,
            messageID: receipt.messageID
        )
    }

    /// Async socket-worker counterpart. It suspends at the main-actor hop
    /// instead of parking an I/O worker behind `DispatchQueue.main.sync`.
    nonisolated func v2WorkspaceAgentSubmitAsync(
        params: [String: Any],
        id: JSONValue?
    ) async -> String {
        var requestParams = params
        let rawWorkspace = params["workspace_id"] as? String
        let rawSurface = params["surface_id"] as? String
        if Self.agentPromptHandleNeedsResolution(rawWorkspace)
            || Self.agentPromptHandleNeedsResolution(rawSurface) {
            let resolved = await v2MainAsync {
                (self.v2UUIDAny(rawWorkspace), self.v2UUIDAny(rawSurface))
            }
            requestParams = Self.agentPromptParamsApplyingResolvedHandles(
                params,
                workspaceID: resolved.0,
                surfaceID: resolved.1
            )
        }
        let parsed = Self.parseAgentPromptSubmit(params: requestParams)
        guard case .success(let workspaceID, let surfaceID, let text) = parsed else {
            guard case .failure(let error) = parsed else {
                return v2Error(
                    id: id?.foundationObject,
                    code: "invalid_params",
                    message: "Invalid agent prompt"
                )
            }
            return v2Result(id: id?.foundationObject, error)
        }
        let receipt = await v2MainAsync {
            self.enqueueAgentPromptSubmission(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                text: text
            )
        }
        return v2Result(
            id: id?.foundationObject,
            Self.agentPromptSocketResult(
                receipt.result,
                messageID: receipt.messageID
            )
        )
    }

    nonisolated static func agentPromptSocketResult(
        _ result: AgentPromptSubmissionResult,
        messageID: UUID? = nil
    ) -> V2CallResult {
        switch result {
        case .submitted(let workspaceID, let surfaceID, let queued):
            var payload: [String: Any] = [
                "submitted": true,
                "queued": queued,
                "workspace_id": workspaceID.uuidString,
                "surface_id": surfaceID.uuidString,
                "delivery_state": queued ? "queued" : "submitted",
            ]
            if let messageID { payload["message_id"] = messageID.uuidString }
            return .ok(payload)
        case .queued(let workspaceID, let surfaceID, let reason):
            var payload: [String: Any] = [
                "submitted": true,
                "queued": true,
                "delivery_state": "queued",
                "workspace_id": workspaceID.uuidString,
                "queue_reason": reason,
            ]
            if let surfaceID { payload["surface_id"] = surfaceID.uuidString }
            if let messageID { payload["message_id"] = messageID.uuidString }
            return .ok(payload)
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
        case .agentBusy(let workspaceID, let surfaceID):
            return .err(
                code: "agent_busy",
                message: String(
                    localized: "socket.workspace.agentSubmit.agentBusy",
                    defaultValue: "The agent is in an active turn. Retry when it returns to its prompt."
                ),
                data: [
                    "workspace_id": workspaceID.uuidString,
                    "surface_id": surfaceID.uuidString,
                    "retryable": true,
                    "retry_after": "agent_prompt_idle",
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
        case .submissionQueueFull(let workspaceID, let surfaceID):
            var data: [String: Any] = [
                "workspace_id": workspaceID.uuidString,
                "retryable": true,
            ]
            if let surfaceID { data["surface_id"] = surfaceID.uuidString }
            return .err(
                code: "submission_queue_full",
                message: String(
                    localized: "socket.workspace.agentSubmit.queueFull",
                    defaultValue: "The agent prompt queue is full. Retry after an earlier prompt is delivered."
                ),
                data: data
            )
        case .promptTooLarge(let workspaceID, let surfaceID, let maximumBytes):
            var data: [String: Any] = [
                "workspace_id": workspaceID.uuidString,
                "maximum_bytes": maximumBytes,
            ]
            if let surfaceID { data["surface_id"] = surfaceID.uuidString }
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.workspace.agentSubmit.promptTooLarge",
                    defaultValue: "Agent prompt text is too large; keep it under 1 MiB."
                ),
                data: data
            )
        }
    }
}
