import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Hook notification summarization
extension CMUXCLI {
    func summarizeClaudeHookNotification(parsedInput: ClaudeHookParsedInput) -> (subtitle: String, body: String) {
        guard let object = parsedInput.object else {
            if let fallback = parsedInput.rawFallback, !fallback.isEmpty {
                return classifyClaudeNotification(signal: fallback, message: fallback)
            }
            return ("Waiting", "Claude is waiting for your input")
        }

        let nested = (object["notification"] as? [String: Any]) ?? (object["data"] as? [String: Any]) ?? [:]
        let signalParts = [
            firstString(in: object, keys: ["event", "event_name", "hook_event_name", "type", "kind"]),
            firstString(in: object, keys: ["notification_type", "matcher", "reason"]),
            firstString(in: nested, keys: ["type", "kind", "reason"])
        ]
        let messageCandidates = [
            firstString(in: object, keys: ["message", "body", "text", "prompt", "error", "description"]),
            firstString(in: nested, keys: ["message", "body", "text", "prompt", "error", "description"])
        ]
        let message = messageCandidates.compactMap { $0 }.first ?? "Claude needs your input"
        let normalizedMessage = normalizedSingleLine(message)
        let signal = signalParts.compactMap { $0 }.joined(separator: " ")
        var classified = classifyClaudeNotification(signal: signal, message: normalizedMessage)

        classified.body = truncate(classified.body, maxLength: 180)
        return classified
    }

    func summarizeAgentHookNotification(
        def: AgentHookDef,
        parsedInput: ClaudeHookParsedInput,
        cwd: String?,
        env: [String: String],
        sessionId: String?
    ) -> AgentHookNotificationSummary {
        guard let object = parsedInput.object else {
            if let fallback = parsedInput.rawFallback, !fallback.isEmpty {
                return classifyAgentHookNotification(
                    def: def,
                    signal: fallback,
                    message: fallback,
                    isFallback: false
                )
            }
            let body = String.localizedStringWithFormat(
                String(localized: "agent.generic.notification.body.sentNotification", defaultValue: "%@ sent a notification"),
                def.displayName
            )
            return classifyAgentHookNotification(def: def, signal: "", message: body, isFallback: true)
        }

        let nested = (object["notification"] as? [String: Any]) ?? (object["data"] as? [String: Any]) ?? [:]
        let extra = (object["extra"] as? [String: Any]) ?? [:]
        let signalParts = [
            firstString(in: object, keys: ["event", "event_name", "hook_event_name", "hookEventName", "type", "kind"]),
            firstString(in: object, keys: ["notification_type", "matcher", "reason"]),
            firstString(in: nested, keys: ["type", "kind", "reason"]),
        ]
        let messageCandidates = [
            firstString(in: object, keys: ["message", "body", "text", "prompt", "summary", "description", "error", "title"]),
            firstString(in: nested, keys: ["message", "body", "text", "prompt", "summary", "description", "error", "title"]),
            firstString(in: extra, keys: ["message", "body", "text", "prompt", "summary", "description", "error", "title"]),
        ]
        let fallbackBody = String.localizedStringWithFormat(
            String(localized: "agent.generic.notification.body.sentNotification", defaultValue: "%@ sent a notification"),
            def.displayName
        )
        let message = messageCandidates.compactMap { $0 }.first ?? fallbackBody
        let signal = signalParts.compactMap { $0 }.joined(separator: " ")
        let normalizedMessage = normalizedSingleLine(message)
        if let hermesApprovalMessage = hermesAgentApprovalNotificationMessage(def: def, object: object) {
            return classifyAgentHookNotification(
                def: def,
                signal: signal,
                message: normalizedSingleLine(hermesApprovalMessage),
                isFallback: false
            )
        }
        if let grokSummary = summarizeGrokAssistantCompletionNotification(
            def: def,
            message: normalizedMessage,
            cwd: cwd,
            env: env,
            sessionId: sessionId,
            matchesMessage: isGrokGenericTurnCompletion
        ) {
            return grokSummary
        }
        if def.name == "grok", isGrokGenericTurnCompletion(normalizedMessage) {
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.completed", defaultValue: "Completed"),
                body: String(localized: "agent.generic.notification.body.taskCompleted", defaultValue: "Task completed"),
                status: .idle,
                isFallback: false
            )
        }
        return classifyAgentHookNotification(
            def: def,
            signal: signal,
            message: normalizedMessage,
            isFallback: message == fallbackBody
        )
    }

    private func summarizeGrokAssistantCompletionNotification(
        def: AgentHookDef,
        message: String,
        cwd: String?,
        env: [String: String],
        sessionId: String?,
        matchesMessage: (String) -> Bool
    ) -> AgentHookNotificationSummary? {
        guard def.name == "grok",
              matchesMessage(message),
              let body = latestGrokAssistantMessage(
                cwd: cwd,
                sessionId: sessionId,
                env: env
              ) else {
            return nil
        }
        return AgentHookNotificationSummary(
            subtitle: String(localized: "agent.generic.notification.subtitle.completed", defaultValue: "Completed"),
            body: truncate(normalizedSingleLine(body), maxLength: 180),
            status: .idle,
            isFallback: false
        )
    }

    private func hermesAgentApprovalNotificationMessage(def: AgentHookDef, object: [String: Any]) -> String? {
        guard def.name == "hermes-agent" else { return nil }
        let event = firstString(in: object, keys: ["hook_event_name", "hookEventName", "event", "event_name"])
        guard event == "pre_approval_request" else { return nil }
        let extra = (object["extra"] as? [String: Any]) ?? [:]
        let command = firstString(in: extra, keys: ["command"])
        let description = firstString(in: extra, keys: ["description", "pattern_key", "patternKey"])

        switch (description, command) {
        case let (description?, command?):
            return String.localizedStringWithFormat(
                String(
                    localized: "agent.hermes.notification.body.approvalCommand",
                    defaultValue: "%1$@: %2$@"
                ),
                description,
                command
            )
        case let (description?, nil):
            return description
        case let (nil, command?):
            return command
        default:
            return nil
        }
    }

    func normalizedAgentHookNotificationMessage(parsedInput: ClaudeHookParsedInput) -> String? {
        guard let object = parsedInput.object else {
            return parsedInput.rawFallback.map(normalizedSingleLine)
        }
        let nested = (object["notification"] as? [String: Any]) ?? (object["data"] as? [String: Any]) ?? [:]
        let extra = (object["extra"] as? [String: Any]) ?? [:]
        let messageCandidates = [
            firstString(in: object, keys: ["message", "body", "text", "prompt", "summary", "description", "error", "title"]),
            firstString(in: nested, keys: ["message", "body", "text", "prompt", "summary", "description", "error", "title"]),
            firstString(in: extra, keys: ["message", "body", "text", "prompt", "summary", "description", "error", "title"]),
        ]
        return messageCandidates.compactMap { $0 }.first.map(normalizedSingleLine)
    }

    func isGrokInternalSessionNotification(_ message: String) -> Bool {
        let lowercasedMessage = message.lowercased()
        return lowercasedMessage.hasPrefix("sessionnotification {")
            || lowercasedMessage.contains("hookexecution {")
            || lowercasedMessage.contains("event_name: user_prompt_submit")
            || lowercasedMessage.contains(#""event_name":"user_prompt_submit""#)
    }

    private func isGrokGenericTurnCompletion(_ message: String) -> Bool {
        message.range(
            of: #"^turn complete(?:d)? in \d+(?:\.\d+)?s\.?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    func latestGrokAssistantMessage(
        cwd: String?,
        sessionId: String?,
        env: [String: String]
    ) -> String? {
        guard let sessionURL = grokSessionDirectory(cwd: cwd, sessionId: sessionId, env: env) else {
            return nil
        }
        let historyURL = sessionURL.appendingPathComponent("chat_history.jsonl", isDirectory: false)
        guard let lines = readRecentTextFileLines(path: historyURL.path, maxBytes: 256 * 1024) else {
            return nil
        }

        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["type"] as? String) == "assistant",
                  let text = extractMessageText(from: object) else {
                continue
            }
            let normalized = normalizedSingleLine(text)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return nil
    }

    private func grokSessionDirectory(
        cwd: String?,
        sessionId: String?,
        env: [String: String]
    ) -> URL? {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty else {
            return nil
        }
        let sessionsRoot = grokSessionsRoot(env: env)
        let fileManager = FileManager.default
        let projectURLs = grokEncodedSessionCWDs(cwd).compactMap { encodedCWD -> URL? in
            let projectURL = sessionsRoot.appendingPathComponent(encodedCWD, isDirectory: true)
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            return projectURL
        }
        guard !projectURLs.isEmpty else {
            return nil
        }

        if let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionId.isEmpty {
            for projectURL in projectURLs {
                let sessionURL = projectURL.appendingPathComponent(sessionId, isDirectory: true)
                var isDirectory = ObjCBool(false)
                if fileManager.fileExists(atPath: sessionURL.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    return sessionURL
                }
            }
            return nil
        }

        return projectURLs.compactMap { projectURL -> URL? in
            guard let sessionURLs = try? fileManager.contentsOfDirectory(
                at: projectURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return nil
            }
            return sessionURLs
                .filter { url in
                    ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                        && fileManager.fileExists(atPath: url.appendingPathComponent("chat_history.jsonl").path)
                }
                .max { lhs, rhs in
                    grokHistoryModifiedDate(lhs) < grokHistoryModifiedDate(rhs)
                }
        }.max { lhs, rhs in
            grokHistoryModifiedDate(lhs) < grokHistoryModifiedDate(rhs)
        }
    }

    private func grokHistoryModifiedDate(_ sessionURL: URL) -> Date {
        (try? sessionURL
            .appendingPathComponent("chat_history.jsonl")
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
    }

    private func grokEncodedSessionCWDs(_ cwd: String) -> [String] {
        guard let rawCwd = grokNormalizedHookPath(cwd) else {
            return []
        }
        var seen = Set<String>()
        return [rawCwd, (rawCwd as NSString).standardizingPath]
            .map(grokEncodedSessionCWD)
            .filter { seen.insert($0).inserted }
    }

    private func grokNormalizedHookPath(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func grokSessionsRoot(env: [String: String]) -> URL {
        let rawHome = normalizedHookValue(env["GROK_HOME"]) ?? "~/.grok"
        return URL(fileURLWithPath: NSString(string: rawHome).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private func grokEncodedSessionCWD(_ cwd: String) -> String {
        var encoded = ""
        for byte in cwd.utf8 {
            let isUnreserved = (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x5F
                || byte == 0x7E
            if isUnreserved {
                encoded.append(Character(UnicodeScalar(byte)))
            } else {
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }

    func classifyAgentHookNotification(
        def: AgentHookDef,
        signal: String,
        message: String,
        isFallback: Bool
    ) -> AgentHookNotificationSummary {
        let lower = "\(signal) \(message)".lowercased()
        if lower.contains("permission") || lower.contains("approve") || lower.contains("approval") || lower.contains("permission_prompt") {
            let body = message.isEmpty
                ? String(localized: "agent.generic.notification.body.approvalNeeded", defaultValue: "Approval needed")
                : message
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.permission", defaultValue: "Permission"),
                body: truncate(body, maxLength: 180),
                status: .needsInput,
                isFallback: isFallback
            )
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("failure") || lower.contains("exception") {
            let body = message.isEmpty
                ? String.localizedStringWithFormat(
                    String(localized: "agent.generic.notification.body.reportedError", defaultValue: "%@ reported an error"),
                    def.displayName
                )
                : message
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.error", defaultValue: "Error"),
                body: truncate(body, maxLength: 180),
                status: .error,
                isFallback: isFallback
            )
        }
        if containsCompletionCue(lower) {
            let body = message.isEmpty
                ? String(localized: "agent.generic.notification.body.taskCompleted", defaultValue: "Task completed")
                : message
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.completed", defaultValue: "Completed"),
                body: truncate(body, maxLength: 180),
                status: .idle,
                isFallback: isFallback
            )
        }
        if containsWaitingCue(lower) {
            let body = message.isEmpty
                ? String(localized: "agent.generic.notification.body.waitingForInput", defaultValue: "Waiting for input")
                : message
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.waiting", defaultValue: "Waiting"),
                body: truncate(body, maxLength: 180),
                status: .needsInput,
                isFallback: isFallback
            )
        }
        if !message.isEmpty {
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.attention", defaultValue: "Attention"),
                body: truncate(message, maxLength: 180),
                status: nil,
                isFallback: isFallback
            )
        }
        let body = String.localizedStringWithFormat(
            String(localized: "agent.generic.notification.body.needsAttention", defaultValue: "%@ needs your attention"),
            def.displayName
        )
        return AgentHookNotificationSummary(
            subtitle: String(localized: "agent.generic.notification.subtitle.attention", defaultValue: "Attention"),
            body: body,
            status: .needsInput,
            isFallback: true
        )
    }

    private func classifyClaudeNotification(signal: String, message: String) -> (subtitle: String, body: String) {
        let lower = "\(signal) \(message)".lowercased()
        if lower.contains("permission") || lower.contains("approve") || lower.contains("approval") || lower.contains("permission_prompt") {
            let body = message.isEmpty ? "Approval needed" : message
            return ("Permission", body)
        }
        if lower.contains("error") || lower.contains("failed") || lower.contains("exception") {
            let body = message.isEmpty ? "Claude reported an error" : message
            return ("Error", body)
        }
        if containsCompletionCue(lower) {
            let body = message.isEmpty ? "Task completed" : message
            return ("Completed", body)
        }
        if containsWaitingCue(lower) {
            let body = message.isEmpty ? "Waiting for input" : message
            return ("Waiting", body)
        }
        // Use the message directly if it's meaningful (not a generic placeholder).
        if !message.isEmpty, message != "Claude needs your input" {
            return ("Attention", message)
        }
        return ("Attention", "Claude needs your attention")
    }

    private func containsCompletionCue(_ lowercasedText: String) -> Bool {
        notificationCueTokens(lowercasedText).contains { token in
            token == "done"
                || token == "succeed"
                || token == "succeeded"
                || token.hasPrefix("complet")
                || token.hasPrefix("finish")
                || token.hasPrefix("success")
        }
    }

    private func containsWaitingCue(_ lowercasedText: String) -> Bool {
        let tokens = notificationCueTokens(lowercasedText)
        for (index, token) in tokens.enumerated() {
            let previous = index > 0 ? tokens[index - 1] : nil
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            if token == "idle" {
                return true
            }
            if token == "wait" || token == "waiting" || token == "awaiting" {
                return true
            }
            if token == "prompt", previous == "idle" || previous == "input" || previous == "user" {
                return true
            }
            if token == "input" {
                if previous == "need" || previous == "needs" || previous == "needed"
                    || previous == "require" || previous == "requires" || previous == "required"
                    || previous == "request" || previous == "requests" || previous == "requested"
                    || previous == "wait" || previous == "waiting" || previous == "awaiting"
                    || previous == "user" || previous == "your"
                    || next == "needed" || next == "required" || next == "requested" {
                    return true
                }
            }
            if token == "question", lowercasedText.contains("?") || tokens.contains(where: {
                $0 == "answer" || $0 == "respond" || $0 == "response" || $0 == "reply"
                    || $0 == "choose" || $0 == "confirm" || $0 == "continue"
            }) {
                return true
            }
        }
        return false
    }

    private func notificationCueTokens(_ lowercasedText: String) -> [Substring] {
        lowercasedText.split { !$0.isLetter && !$0.isNumber }
    }

    func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    func normalizedSingleLine(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, maxLength - 1))
        return String(value[..<index]) + "…"
    }

    func sanitizeNotificationField(_ value: String) -> String {
        return normalizedSingleLine(value)
            .replacingOccurrences(of: "|", with: "¦")
    }

    func notificationPayload(title: String, subtitle: String, body: String) -> String {
        "\(sanitizeNotificationField(title))|\(sanitizeNotificationField(subtitle))|\(sanitizeNotificationField(body))"
    }

    func redactClaudeSensitiveSpans(_ value: String) -> String {
        let patterns: [(pattern: String, replacement: String)] = [
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<email>"),
            (#"(?:~|/)[^\s\"']+"#, "<path>"),
            (#"\b(?:sk|rk|sess|token|key|secret|api[_-]?key)[A-Za-z0-9._:-]{8,}\b"#, "<token>"),
            (#"\b[A-Za-z0-9_-]{24,}\b"#, "<token>")
        ]
        return patterns.reduce(value) { partial, entry in
            partial.replacingOccurrences(
                of: entry.pattern,
                with: entry.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

}
