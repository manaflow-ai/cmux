import Foundation

extension CMUXCLI {
    /// Finds a provider failure banner in a Claude stop payload or its transcript.
    func summarizeClaudeAbnormalStop(
        parsedInput: ClaudeHookParsedInput
    ) -> AgentHookNotificationSummary? {
        let object = parsedInput.object
        let nestedObjects = [
            object?["notification"] as? [String: Any],
            object?["data"] as? [String: Any],
            object?["extra"] as? [String: Any],
            object?["payload"] as? [String: Any],
        ].compactMap { $0 }
        let signalParts = [
            "Stop",
            firstString(in: object ?? [:], keys: ["reason", "stop_reason", "stopReason", "terminationReason", "type", "kind"]),
        ] + nestedObjects.map {
            firstString(in: $0, keys: ["reason", "stop_reason", "stopReason", "terminationReason", "type", "kind"])
        }
        let signal = signalParts.compactMap { $0 }.joined(separator: " ")
        let messages = [
            claudeAssistantMessageFromHookPayload(object),
            firstString(in: object ?? [:], keys: ["error", "message", "description"]),
        ] + nestedObjects.flatMap {
            [firstString(in: $0, keys: [
                "error", "message", "description",
                "last_assistant_message", "lastAssistantMessage", "last_agent_message", "lastAgentMessage",
            ])]
        } + [
            parsedInput.transcriptPath.flatMap { readTranscriptSummary(path: $0)?.lastAssistantMessage },
            parsedInput.rawFallback,
            signal == "Stop" ? nil : signal,
        ]

        let normalizedMessages = messages
            .compactMap { $0 }
            .map(normalizedSingleLine)
            .filter { !$0.isEmpty }
        // A stop payload can carry both a stale provider error and a separate
        // Ctrl+C/`/exit` message. Treat the user boundary as authoritative for
        // the whole payload instead of allowing a later field to re-promote the
        // stale error.
        guard !AgentHookNotificationClassifier.isUserInitiatedStop(
            signal: signal,
            message: normalizedMessages.joined(separator: " ")
        ) else {
            return nil
        }

        for message in normalizedMessages {
            if let summary = AgentHookNotificationClassifier.classifyAbnormalStop(
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
        let nestedObjects = [
            object,
            object?["notification"] as? [String: Any],
            object?["data"] as? [String: Any],
            object?["extra"] as? [String: Any],
            object?["payload"] as? [String: Any],
        ].compactMap { $0 }
        let reason = nestedObjects.lazy.compactMap {
            firstString(
                in: $0,
                keys: ["terminationReason", "stop_reason", "stopReason", "reason", "type", "kind"]
            )
        }.first
        let signal = ["Stop", reason].compactMap { $0 }.joined(separator: " ")
        let messages = nestedObjects.compactMap {
            firstString(
                in: $0,
                keys: ["last_assistant_message", "lastAssistantMessage", "last_agent_message", "lastAgentMessage"]
            )
        } + [fallbackMessage, reason].compactMap { $0 }
        for message in messages.compactMap({ $0 }).map(normalizedSingleLine).filter({ !$0.isEmpty }) {
            guard AgentHookNotificationClassifier.abnormalStopClass(signal: signal, message: message) != nil else {
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
        let object = input.object
        let reason = firstString(
            in: object ?? [:],
            keys: ["terminationReason", "stop_reason", "stopReason", "reason", "type", "kind"]
        )
        let signal = ["Stop", reason].compactMap { $0 }.joined(separator: " ")
        let messages = [
            lastMessage,
            firstString(in: object ?? [:], keys: ["error", "message", "description"]),
            input.rawFallback,
            reason,
        ]
        let normalizedMessages = messages
            .compactMap { $0 }
            .map(normalizedSingleLine)
            .filter { !$0.isEmpty }
        guard !AgentHookNotificationClassifier.isUserInitiatedStop(
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
