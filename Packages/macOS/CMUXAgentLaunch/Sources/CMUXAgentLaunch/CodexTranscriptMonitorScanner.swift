import Foundation

/// Extracts monitor state from a bounded tail of a Codex JSONL transcript.
public struct CodexTranscriptMonitorScanner: Sendable {
    /// Creates a stateless transcript scanner.
    public init() {}

    /// Scans transcript lines for input requests and the requested turn's result.
    ///
    /// - Parameters:
    ///   - lines: A bounded, oldest-to-newest JSONL tail.
    ///   - turnID: The turn to monitor, or `nil` to monitor the current turn.
    ///   - excludingCallIDs: Input-call identities already published by this monitor.
    /// - Returns: The newest monitor-relevant state in the supplied tail.
    public func scan(
        lines: [String],
        turnID: String?,
        excludingCallIDs: Set<String> = []
    ) -> CodexTranscriptMonitorSnapshot {
        let normalizedTurnID = normalized(turnID)
        var sawRelevantTurn = normalizedTurnID == nil
        var sawAssistantMessage = false
        var sawTerminalTurn = false
        var failure: CodexTranscriptMonitorFailure?
        var failureCanPublishBeforeTerminal = false
        var userInput: CodexTranscriptMonitorUserInput?

        for line in lines {
            guard let object = jsonObject(line), let objectType = object["type"] as? String else {
                continue
            }

            if (normalizedTurnID == nil || sawRelevantTurn), assistantMessageExists(in: object) {
                sawAssistantMessage = true
                failure = nil
                failureCanPublishBeforeTerminal = false
            }

            if objectType == "turn_context", let payload = object["payload"] as? [String: Any] {
                let payloadTurnID = firstString(in: payload, keys: ["turn_id", "turnId"])
                sawRelevantTurn = normalizedTurnID.map { $0 == payloadTurnID } ?? true
                continue
            }

            if objectType == "response_item",
               let payload = object["payload"] as? [String: Any],
               let candidate = functionCallUserInput(
                   payload,
                   turnID: normalizedTurnID,
                   sawRelevantTurn: sawRelevantTurn,
                   excluding: excludingCallIDs
               ) {
                userInput = candidate
                continue
            }

            guard objectType == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else {
                continue
            }

            switch eventType {
            case "task_started":
                let payloadTurnID = firstString(in: payload, keys: ["turn_id", "turnId"])
                sawRelevantTurn = normalizedTurnID.map { $0 == payloadTurnID } ?? true
                guard sawRelevantTurn else { continue }
                failure = nil
                failureCanPublishBeforeTerminal = false

            case "request_user_input":
                if let candidate = eventUserInput(
                    payload,
                    turnID: normalizedTurnID,
                    sawRelevantTurn: sawRelevantTurn,
                    excluding: excludingCallIDs
                ) {
                    userInput = candidate
                }

            case "error", "stream_error":
                let payloadTurnID = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let normalizedTurnID, let payloadTurnID {
                    guard payloadTurnID == normalizedTurnID else { continue }
                    sawRelevantTurn = true
                }
                let candidate = reportedFailure(
                    payload,
                    streamError: eventType == "stream_error"
                ) ?? CodexTranscriptMonitorFailure(
                    kind: .reported,
                    message: nil,
                    codexErrorInfo: nil,
                    additionalDetails: nil,
                    isStreamError: eventType == "stream_error"
                )
                failure = candidate
                failureCanPublishBeforeTerminal = normalizedTurnID == nil
                    || payloadTurnID == normalizedTurnID
                    || sawRelevantTurn

            case "task_complete", "turn_complete":
                let payloadTurnID = firstString(in: payload, keys: ["turn_id", "turnId"])
                if let normalizedTurnID {
                    guard payloadTurnID == normalizedTurnID else { continue }
                }
                sawRelevantTurn = true
                sawTerminalTurn = true
                userInput = nil
                failureCanPublishBeforeTerminal = false
                if let terminalError = payload["error"] as? [String: Any],
                   let candidate = reportedFailure(terminalError, streamError: false) {
                    failure = candidate
                } else if payload["error"] is [String: Any] {
                    failure = CodexTranscriptMonitorFailure(
                        kind: .reported,
                        message: nil,
                        codexErrorInfo: nil,
                        additionalDetails: nil,
                        isStreamError: false
                    )
                } else if let terminalError = jsonStringValue(payload["error"]) {
                    failure = CodexTranscriptMonitorFailure(
                        kind: .reported,
                        message: terminalError,
                        codexErrorInfo: nil,
                        additionalDetails: nil,
                        isStreamError: false
                    )
                } else if normalized(payload["last_agent_message"] as? String) != nil {
                    sawAssistantMessage = true
                    failure = nil
                } else if failure == nil, !sawAssistantMessage {
                    failure = CodexTranscriptMonitorFailure(
                        kind: .missingFinalResponse,
                        message: nil,
                        codexErrorInfo: nil,
                        additionalDetails: nil,
                        isStreamError: false
                    )
                }

            default:
                break
            }
        }

        let state: CodexTranscriptMonitorState
        if let failure, failureCanPublishBeforeTerminal {
            state = .failure(failure)
        } else if failure != nil, normalizedTurnID != nil, !sawRelevantTurn {
            state = .pending
        } else if !sawTerminalTurn {
            state = .pending
        } else if let failure {
            state = .failure(failure)
        } else if sawTerminalTurn || sawAssistantMessage {
            state = .healthy
        } else {
            state = .pending
        }
        return CodexTranscriptMonitorSnapshot(userInput: userInput, state: state)
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private func assistantMessageExists(in object: [String: Any]) -> Bool {
        guard (object["type"] as? String) == "response_item",
              let payload = object["payload"] as? [String: Any],
              (payload["type"] as? String) == "message",
              (payload["role"] as? String) == "assistant",
              let content = payload["content"] as? [[String: Any]] else {
            return false
        }
        return content.contains { block in
            normalized(block["text"] as? String) != nil
        }
    }

    private func eventUserInput(
        _ payload: [String: Any],
        turnID: String?,
        sawRelevantTurn: Bool,
        excluding callIDs: Set<String>
    ) -> CodexTranscriptMonitorUserInput? {
        let payloadTurnID = firstString(in: payload, keys: ["turn_id", "turnId"])
        if let turnID {
            if let payloadTurnID {
                guard payloadTurnID == turnID else { return nil }
            } else {
                guard sawRelevantTurn else { return nil }
            }
        }
        return userInput(
            payload,
            payloadTurnID: payloadTurnID,
            turnID: turnID,
            fallbackCallID: nil,
            excluding: callIDs
        )
    }

    private func functionCallUserInput(
        _ payload: [String: Any],
        turnID: String?,
        sawRelevantTurn: Bool,
        excluding callIDs: Set<String>
    ) -> CodexTranscriptMonitorUserInput? {
        guard (payload["type"] as? String) == "function_call",
              (payload["name"] as? String) == "request_user_input" else {
            return nil
        }
        let arguments = functionCallArguments(payload)
        let payloadTurnID = firstString(in: payload, keys: ["turn_id", "turnId"])
            ?? arguments.flatMap { firstString(in: $0, keys: ["turn_id", "turnId"]) }
        if let turnID {
            if let payloadTurnID {
                guard payloadTurnID == turnID else { return nil }
            } else {
                guard sawRelevantTurn else { return nil }
            }
        }
        return userInput(
            arguments ?? payload,
            payloadTurnID: payloadTurnID,
            turnID: turnID,
            fallbackCallID: firstString(in: payload, keys: ["call_id", "callId"]),
            excluding: callIDs
        )
    }

    private func functionCallArguments(_ payload: [String: Any]) -> [String: Any]? {
        if let arguments = payload["arguments"] as? [String: Any] { return arguments }
        guard let raw = payload["arguments"] as? String,
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private func userInput(
        _ payload: [String: Any],
        payloadTurnID: String?,
        turnID: String?,
        fallbackCallID: String?,
        excluding callIDs: Set<String>
    ) -> CodexTranscriptMonitorUserInput? {
        let question = questionText(payload)
        let callID = normalized(firstString(in: payload, keys: ["call_id", "callId"]) ?? fallbackCallID)
            ?? "\(payloadTurnID ?? turnID ?? "session"):\(question ?? "request_user_input")"
        guard !callIDs.contains(callID) else { return nil }
        return CodexTranscriptMonitorUserInput(callID: callID, question: question)
    }

    private func questionText(_ payload: [String: Any]) -> String? {
        guard let questions = payload["questions"] as? [[String: Any]] else { return nil }
        for question in questions {
            guard let raw = firstString(in: question, keys: ["question", "header", "id"]) else {
                continue
            }
            let text = singleLine(raw)
            if !text.isEmpty { return String(text.prefix(220)) }
        }
        return nil
    }

    private func reportedFailure(
        _ payload: [String: Any],
        streamError: Bool
    ) -> CodexTranscriptMonitorFailure? {
        let message = firstString(in: payload, keys: ["message", "error", "body", "text", "description"])
        let additionalDetails = jsonStringValue(payload["additional_details"] ?? payload["additionalDetails"])
        let codexErrorInfo = jsonStringValue(payload["codex_error_info"] ?? payload["codexErrorInfo"])
        guard message != nil || additionalDetails != nil || codexErrorInfo != nil else { return nil }
        return CodexTranscriptMonitorFailure(
            kind: .reported,
            message: message,
            codexErrorInfo: codexErrorInfo,
            additionalDetails: additionalDetails,
            isStreamError: streamError
        )
    }

    private func jsonStringValue(_ value: Any?) -> String? {
        if let string = value as? String { return normalized(singleLine(string)) }
        guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return normalized(singleLine(string))
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = normalized(object[key] as? String) { return value }
        }
        return nil
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
