import Foundation

/// Completion text plus the transcript message already read for the stop hook.
struct ClaudeHookStopSummary {
    let subtitle: String
    let body: String
    let transcriptMessage: String?
}

extension CMUXCLI {
    /// Payload keys that describe why a managed-agent turn stopped, in priority order.
    private static let abnormalStopReasonKeys = [
        "terminationReason", "termination_reason", "stop_reason", "stopReason", "reason", "type", "kind",
    ]

    /// Payload keys that can carry a terminal provider message.
    private static let abnormalStopMessageKeys = [
        "error", "message", "description",
        "last_assistant_message", "lastAssistantMessage", "last_agent_message", "lastAgentMessage",
        "assistantPreamble", "assistant_preamble", "assistant_response", "assistantResponse",
    ]

    /// Assistant-message aliases used when a provider renders an error banner as its final reply.
    private static let abnormalStopAssistantMessageKeys = [
        "last_assistant_message", "lastAssistantMessage", "last_agent_message", "lastAgentMessage",
        "assistantPreamble", "assistant_preamble", "assistant_response", "assistantResponse",
    ]

    /// Returns the hook dictionaries whose fields may describe a terminal stop.
    private func abnormalStopNestedObjects(from object: [String: Any]?) -> [[String: Any]] {
        guard let object else { return [] }
        return [
            object,
            object["notification"] as? [String: Any],
            object["data"] as? [String: Any],
            object["extra"] as? [String: Any],
            object["payload"] as? [String: Any],
        ].compactMap { $0 }
    }

    /// Collects every non-empty string under the supplied aliases.
    private func abnormalStopStrings(
        in object: [String: Any],
        keys: [String]
    ) -> [String] {
        keys.compactMap { key in
            guard let value = object[key] as? String else { return nil }
            let normalized = normalizedSingleLine(value)
            return normalized.isEmpty ? nil : normalized
        }
    }

    /// Gathers the signal and message fields for one Claude stop boundary.
    private func claudeAbnormalStopInputs(
        parsedInput: ClaudeHookParsedInput,
        transcriptMessage: String?
    ) -> (signal: String, messages: [String]) {
        let nestedObjects = abnormalStopNestedObjects(from: parsedInput.object)
        let signalParts = ["Stop"] + nestedObjects.flatMap {
            abnormalStopStrings(in: $0, keys: Self.abnormalStopReasonKeys)
        }
        let signal = signalParts.joined(separator: " ")
        let messages = nestedObjects.flatMap {
            abnormalStopStrings(in: $0, keys: Self.abnormalStopMessageKeys)
        } + [
            transcriptMessage,
            parsedInput.rawFallback,
            signal == "Stop" ? nil : signal,
        ].compactMap { $0 }
        return (signal, messages)
    }

    /// Reports whether a Claude stop carries an explicit user cancellation cue.
    func isClaudeUserInitiatedStop(
        parsedInput: ClaudeHookParsedInput,
        transcriptMessage: String? = nil
    ) -> Bool {
        let inputs = claudeAbnormalStopInputs(
            parsedInput: parsedInput,
            transcriptMessage: transcriptMessage
        )
        return AgentHookAbnormalStopClassifier().isUserInitiatedStop(
            signal: inputs.signal,
            message: inputs.messages.joined(separator: " ")
        )
    }

    /// Reports whether a generic managed-agent stop carries a user cancellation cue.
    func isManagedAgentUserInitiatedStop(input: ClaudeHookParsedInput) -> Bool {
        let nestedObjects = abnormalStopNestedObjects(from: input.object)
        let signal = (["Stop"] + nestedObjects.flatMap {
            abnormalStopStrings(in: $0, keys: Self.abnormalStopReasonKeys)
        }).joined(separator: " ")
        let messages = nestedObjects.flatMap {
            abnormalStopStrings(in: $0, keys: Self.abnormalStopMessageKeys)
        } + [input.rawFallback].compactMap { $0 }
        return AgentHookAbnormalStopClassifier().isUserInitiatedStop(
            signal: signal,
            message: messages.joined(separator: " ")
        )
    }

    /// Finds a provider failure banner in a Claude stop payload or its transcript.
    func summarizeClaudeAbnormalStop(
        parsedInput: ClaudeHookParsedInput,
        transcriptMessage: String? = nil
    ) -> AgentHookNotificationSummary? {
        let inputs = claudeAbnormalStopInputs(
            parsedInput: parsedInput,
            transcriptMessage: transcriptMessage
        )
        let signal = inputs.signal
        let messages = inputs.messages

        let normalizedMessages = messages
        // A stop payload can carry both a stale provider error and a separate
        // Ctrl+C/`/exit` message. Treat the user boundary as authoritative for
        // the whole payload instead of allowing a later field to re-promote the
        // stale error.
        guard !AgentHookAbnormalStopClassifier().isUserInitiatedStop(
            signal: signal,
            message: normalizedMessages.joined(separator: " ")
        ) else {
            return nil
        }

        for message in normalizedMessages {
            if let summary = AgentHookAbnormalStopClassifier().summary(
                displayName: String(localized: "cli.claude-hook.notification.title", defaultValue: "Claude Code"),
                signal: signal,
                message: message,
                isFallback: parsedInput.rawFallback != nil
            ) {
                return summary
            }
        }
        return nil
    }

    /// Converts a terminal Codex banner into the shared failure-candidate shape.
    func codexAbnormalStopBannerCandidate(
        from object: [String: Any]?,
        fallbackMessage: String? = nil
    ) -> CodexHookFailureCandidate? {
        let nestedObjects = abnormalStopNestedObjects(from: object)
        let reason = nestedObjects.lazy.compactMap {
            abnormalStopStrings(in: $0, keys: Self.abnormalStopReasonKeys).first
        }.first
        let signal = ["Stop", reason].compactMap { $0 }.joined(separator: " ")
        let messages = nestedObjects.flatMap {
            abnormalStopStrings(in: $0, keys: Self.abnormalStopAssistantMessageKeys)
        } + [fallbackMessage, reason].compactMap { $0 }
        for message in messages {
            let message = normalizedSingleLine(message)
            guard !message.isEmpty else { continue }
            guard AgentHookAbnormalStopClassifier().abnormalStopClass(signal: signal, message: message) != nil else {
                continue
            }
            return CodexHookFailureCandidate(
                message: message,
                codexErrorInfo: nil,
                additionalDetails: nil,
                isStreamError: false,
                isAbnormalStopBanner: true
            )
        }
        return nil
    }

    /// Classifies abnormal stops for generic managed-agent hooks.
    func summarizeGenericAbnormalStop(
        def: AgentHookDef,
        input: ClaudeHookParsedInput,
        lastMessage: String?
    ) -> AgentHookNotificationSummary? {
        guard def.name != "codex", def.name != "antigravity" else { return nil }
        let nestedObjects = abnormalStopNestedObjects(from: input.object)
        let reasonMessages = nestedObjects.flatMap {
            abnormalStopStrings(in: $0, keys: Self.abnormalStopReasonKeys)
        }
        let signal = (["Stop"] + reasonMessages).joined(separator: " ")
        let messages = nestedObjects.flatMap {
            abnormalStopStrings(in: $0, keys: Self.abnormalStopMessageKeys)
        } + [
            lastMessage,
            input.rawFallback,
        ] + reasonMessages
        let normalizedMessages = messages
        guard !AgentHookAbnormalStopClassifier().isUserInitiatedStop(
            signal: signal,
            message: normalizedMessages.joined(separator: " ")
        ) else {
            return nil
        }
        for message in normalizedMessages {
            let summary = AgentHookNotificationClassifier.classify(
                displayName: def.displayName,
                signal: signal,
                message: message,
                isFallback: false
            )
            if summary.status == .error, summary.notifyCategory == .other {
                return summary
            }
        }
        return nil
    }

    /// Returns the sidebar status text for a known Codex abnormal-stop class.
    func codexAbnormalStopStatusValue(_ failureClass: AgentHookAbnormalStopClass) -> String {
        switch failureClass {
        case .capacity:
            return String(localized: "agent.codex.error.status.capacity", defaultValue: "Codex model at capacity")
        case .quota:
            return String(localized: "agent.codex.error.status.quota", defaultValue: "Codex quota exhausted")
        case .rateLimit:
            return String(localized: "agent.codex.error.status.rateLimit", defaultValue: "Codex rate limit")
        case .timeout:
            return String(localized: "agent.codex.error.status.timeout", defaultValue: "Codex request timed out")
        case .authentication:
            return String(localized: "agent.codex.error.status.auth", defaultValue: "Codex auth error")
        case .network:
            return String(localized: "agent.codex.error.status.network", defaultValue: "Codex network error")
        case .generic:
            return String(localized: "agent.codex.error.status.generic", defaultValue: "Codex error")
        }
    }
}
