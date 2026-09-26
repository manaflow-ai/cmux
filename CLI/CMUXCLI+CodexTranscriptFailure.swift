import CmuxAgentHooks
import Foundation

extension CMUXCLI {
    func readCodexTranscriptFailure(
        path: String,
        turnId: String? = nil,
        requireTerminalCompletion: Bool = false
    ) -> CodexTranscriptFailureReadResult {
        guard let lines = readRecentTextFileLines(path: path, maxBytes: 512 * 1024) else {
            return .unavailable
        }

        var candidate: CodexHookFailureCandidate?
        var candidateCanPublishBeforeTerminal = false
        var sawAssistantMessage = false
        var sawTerminalTurn = false
        var sawRelevantTurn = turnId == nil
        var lastAssistantMessage: String?
        var terminalBoundaryMessage: String?
        var terminalStopSignal = "Stop"
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                continue
            }

            let assistantMessageTurnId = (object["payload"] as? [String: Any]).flatMap {
                firstString(in: $0, keys: ["turn_id", "turnId"])
            }
            if (turnId == nil
                || assistantMessageTurnId == turnId
                || (assistantMessageTurnId == nil && sawRelevantTurn)),
               codexTranscriptLineHasAssistantMessage(object) {
                sawAssistantMessage = true
                candidate = nil
                candidateCanPublishBeforeTerminal = false
                if let payload = object["payload"] as? [String: Any],
                   let assistantText = codexTranscriptMessageText(payload) {
                    lastAssistantMessage = truncate(normalizedSingleLine(assistantText), maxLength: 200)
                }
            }

            guard (object["type"] as? String) == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else {
                continue
            }

            switch eventType {
            case "task_started":
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let turnId {
                    guard payloadTurnId == turnId else {
                        continue
                    }
                }
                sawRelevantTurn = true
                candidate = nil
                candidateCanPublishBeforeTerminal = false
            case "error":
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let turnId, let payloadTurnId {
                    guard payloadTurnId == turnId else {
                        continue
                    }
                    sawRelevantTurn = true
                }
                if let failure = codexHookFailureCandidate(
                    from: payload,
                    isStreamError: false,
                    requireFailureSignal: false
                ) {
                    candidate = failure
                    candidateCanPublishBeforeTerminal = turnId == nil || payloadTurnId == turnId || sawRelevantTurn
                }
            case "stream_error":
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let turnId, let payloadTurnId {
                    guard payloadTurnId == turnId else {
                        continue
                    }
                    sawRelevantTurn = true
                }
                if let failure = codexHookFailureCandidate(
                    from: payload,
                    isStreamError: true,
                    requireFailureSignal: false
                ) {
                    candidate = failure
                    candidateCanPublishBeforeTerminal = turnId == nil || payloadTurnId == turnId || sawRelevantTurn
                }
            case "agent_message":
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let turnId {
                    if let payloadTurnId {
                        guard payloadTurnId == turnId else {
                            continue
                        }
                    } else {
                        guard sawRelevantTurn else {
                            continue
                        }
                    }
                }
                sawRelevantTurn = true
                guard let message = firstString(in: payload, keys: ["message", "text", "body"])
                else {
                    continue
                }
                let normalizedMessage = normalizedSingleLine(message)
                guard !normalizedMessage.isEmpty else {
                    continue
                }
                sawAssistantMessage = true
                lastAssistantMessage = truncate(normalizedMessage, maxLength: 200)
                candidate = nil
                candidateCanPublishBeforeTerminal = false
            case "task_complete", "turn_complete":
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let turnId {
                    guard payloadTurnId == turnId else {
                        continue
                    }
                }
                sawRelevantTurn = true
                sawTerminalTurn = true
                let terminalReason = firstString(
                    in: payload,
                    keys: ["reason", "stop_reason", "stopReason", "terminationReason", "termination_reason"]
                )
                // Keep structured stop reasons adjacent to the stop marker so
                // cancellation aliases (for example `user_requested`) remain
                // recognizable even when the event name is also present.
                terminalStopSignal = ["Stop", terminalReason, eventType]
                    .compactMap { $0 }
                    .joined(separator: " ")
                // Codex persists fatal turn failures inside task_complete.error. Standalone
                // error events are transient, and a failed turn may still contain partial
                // assistant output, so the terminal error must be authoritative.
                if let terminalError = payload["error"] as? [String: Any] {
                    terminalBoundaryMessage = firstString(
                        in: terminalError,
                        keys: ["message", "error", "body", "text", "description", "reason"]
                    ) ?? codexHookStringValue(payload["error"])
                    if let failure = codexHookFailureCandidate(
                        from: terminalError,
                        requireFailureSignal: false
                    ) {
                        candidate = failure
                    }
                    candidateCanPublishBeforeTerminal = false
                } else if let terminalError = codexHookStringValue(payload["error"]) {
                    terminalBoundaryMessage = terminalError
                    if !AgentHookAbnormalStopClassifier().isUserInitiatedStop(
                        signal: terminalStopSignal,
                        message: terminalError
                    ) {
                        candidate = CodexHookFailureCandidate(
                            message: terminalError,
                            codexErrorInfo: nil,
                            additionalDetails: nil,
                            isStreamError: false
                        )
                    }
                    candidateCanPublishBeforeTerminal = false
                } else if let lastMessage = firstString(
                    in: payload,
                    keys: ["last_agent_message", "lastAgentMessage"]
                ),
                   !lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sawAssistantMessage = true
                    lastAssistantMessage = truncate(normalizedSingleLine(lastMessage), maxLength: 200)
                    terminalBoundaryMessage = lastAssistantMessage
                    candidate = nil
                    candidateCanPublishBeforeTerminal = false
                } else if candidate == nil && !sawAssistantMessage && terminalBoundaryMessage == nil {
                    candidate = CodexHookFailureCandidate(
                        message: String(
                            localized: "agent.codex.error.noFinalResponse",
                            defaultValue: "Codex ended before sending a final response"
                        ),
                        codexErrorInfo: nil,
                        additionalDetails: nil,
                        isStreamError: false
                    )
                    candidateCanPublishBeforeTerminal = false
                }
            case "turn_aborted":
                let payloadTurnId = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let turnId {
                    guard payloadTurnId == turnId else {
                        continue
                    }
                }
                sawRelevantTurn = true
                sawTerminalTurn = true
                let reason = firstString(in: payload, keys: ["reason", "stop_reason", "stopReason", "terminationReason", "termination_reason", "message", "error"])
                terminalStopSignal = ["Stop", reason, "turn_aborted"].compactMap { $0 }.joined(separator: " ")
                terminalBoundaryMessage = reason ?? codexHookStringValue(payload["error"])
                if let failure = codexHookFailureCandidate(
                    from: payload,
                    requireFailureSignal: false
                ), let abnormalClass = AgentHookAbnormalStopClassifier().abnormalStopClass(
                    signal: terminalStopSignal,
                    message: failure.message
                ) {
                    terminalBoundaryMessage = failure.message
                    candidate = CodexHookFailureCandidate(
                        message: failure.message,
                        codexErrorInfo: failure.codexErrorInfo,
                        additionalDetails: failure.additionalDetails,
                        isStreamError: failure.isStreamError,
                        isAbnormalStopBanner: abnormalClass != .generic
                    )
                    candidateCanPublishBeforeTerminal = false
                }
            default:
                break
            }
        }

        // A user abort is authoritative for the whole terminal boundary. Do
        // not let an earlier transient error event or stale assistant banner
        // win the race and turn Ctrl+C into a provider-error notification.
        if AgentHookAbnormalStopClassifier().isUserInitiatedStop(
            signal: terminalStopSignal,
            message: [terminalBoundaryMessage, lastAssistantMessage]
                .compactMap { $0 }
                .joined(separator: " ")
        ) {
            return .healthy(lastAssistantMessage: lastAssistantMessage)
        }

        if let candidate, candidateCanPublishBeforeTerminal {
            return .failure(candidate)
        }
        if candidate != nil, turnId != nil, !sawRelevantTurn {
            return .pending
        }
        if requireTerminalCompletion, !sawTerminalTurn {
            return .pending
        }
        if let candidate {
            return .failure(candidate)
        }
        if let lastAssistantMessage,
           AgentHookAbnormalStopClassifier().abnormalStopClass(
               signal: terminalStopSignal,
               message: lastAssistantMessage
           ) != nil,
           (!requireTerminalCompletion || sawTerminalTurn) {
            return .failure(
                CodexHookFailureCandidate(
                    message: lastAssistantMessage,
                    codexErrorInfo: nil,
                    additionalDetails: nil,
                    isStreamError: false,
                    isAbnormalStopBanner: true
                )
            )
        }
        if !sawTerminalTurn, !sawAssistantMessage {
            return .pending
        }
        return .healthy(lastAssistantMessage: lastAssistantMessage)
    }

}
