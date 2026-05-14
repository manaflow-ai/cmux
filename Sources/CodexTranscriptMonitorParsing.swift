import Foundation

struct CodexTranscriptFailureCandidate {
    let message: String
    let codexErrorInfo: String?
    let additionalDetails: String?
    let isStreamError: Bool
}

struct CodexTranscriptUserInputCandidate {
    let callId: String
    let question: String?
}

enum CodexTranscriptMonitorParser {
    static func transcriptLineHasAssistantMessage(payload: [String: Any]) -> Bool {
        guard (payload["type"] as? String) == "message",
              (payload["role"] as? String) == "assistant",
              let content = payload["content"] as? [[String: Any]] else {
            return false
        }
        return content.contains { block in
            guard let text = block["text"] as? String else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func failureCandidate(
        from object: [String: Any],
        isStreamError: Bool,
        requireFailureSignal: Bool = true
    ) -> CodexTranscriptFailureCandidate? {
        let message = firstString(in: object, keys: ["message", "error", "body", "text", "description"])
        let additionalDetails = hookStringValue(object["additional_details"] ?? object["additionalDetails"])
        let codexErrorInfo = hookStringValue(object["codex_error_info"] ?? object["codexErrorInfo"])
        let eventType = firstString(in: object, keys: ["type", "kind"])?.lowercased()
        let typedFailure = eventType == "error" || eventType == "stream_error"
        let hasExplicitErrorField = object["error"].map { !($0 is NSNull) } ?? false
        let signal = [message, additionalDetails, codexErrorInfo]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        guard !requireFailureSignal ||
              typedFailure ||
              hasExplicitErrorField ||
              codexErrorInfo != nil ||
              signal.contains("error") ||
              signal.contains("failed") ||
              signal.contains("exception") ||
              signal.contains("usage limit") ||
              signal.contains("rate limit") ||
              signal.contains("stream disconnected") ||
              signal.contains("connection") ||
              signal.contains("unauthorized") else {
            return nil
        }
        return CodexTranscriptFailureCandidate(
            message: message ?? additionalDetails ?? codexErrorInfo ?? String(
                localized: "agent.codex.error.defaultMessage",
                defaultValue: "Codex reported an error"
            ),
            codexErrorInfo: codexErrorInfo,
            additionalDetails: additionalDetails,
            isStreamError: isStreamError || eventType == "stream_error"
        )
    }

    static func summarizeFailure(_ candidate: CodexTranscriptFailureCandidate) -> CodexTranscriptFailureSummary {
        let signal = [
            candidate.message,
            candidate.codexErrorInfo,
            candidate.additionalDetails,
            candidate.isStreamError ? "stream_error" : nil
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        let subtitle: String
        let statusValue: String
        if signal.contains("usage_limit") ||
            signal.contains("usage limit") ||
            signal.contains("rate limit") ||
            signal.contains("quota") {
            subtitle = String(localized: "agent.codex.error.subtitle.rateLimit", defaultValue: "Rate limit")
            statusValue = String(localized: "agent.codex.error.status.rateLimit", defaultValue: "Codex rate limit")
        } else if signal.contains("unauthorized") ||
                    signal.contains("auth") ||
                    signal.contains("login") ||
                    signal.contains("api key") {
            subtitle = String(localized: "agent.codex.error.subtitle.auth", defaultValue: "Auth error")
            statusValue = String(localized: "agent.codex.error.status.auth", defaultValue: "Codex auth error")
        } else if candidate.isStreamError ||
                    signal.contains("network") ||
                    signal.contains("connection") ||
                    signal.contains("stream disconnected") ||
                    signal.contains("timed out") {
            subtitle = String(localized: "agent.codex.error.subtitle.network", defaultValue: "Network error")
            statusValue = String(localized: "agent.codex.error.status.network", defaultValue: "Codex network error")
        } else {
            subtitle = String(localized: "agent.codex.error.subtitle.generic", defaultValue: "Error")
            statusValue = String(localized: "agent.codex.error.status.generic", defaultValue: "Codex error")
        }

        let detail = [candidate.message, candidate.codexErrorInfo, candidate.additionalDetails]
            .compactMap { normalizedValue($0).map(normalizedSingleLine) }
            .first { !$0.isEmpty } ?? candidate.message
        return CodexTranscriptFailureSummary(
            statusValue: statusValue,
            subtitle: subtitle,
            body: truncate(detail, maxLength: 220)
        )
    }

    static func codexFunctionCallArgumentsObject(from payload: [String: Any]) -> [String: Any]? {
        if let arguments = payload["arguments"] as? [String: Any] {
            return arguments
        }
        guard let rawArguments = payload["arguments"] as? String,
              let data = rawArguments.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        return arguments
    }

    static func userInputQuestionText(from payload: [String: Any]) -> String? {
        let questions = payload["questions"] as? [[String: Any]] ?? []
        for question in questions {
            let text = firstString(in: question, keys: ["question", "header", "id"])
            let normalized = text.map(normalizedSingleLine)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized, !normalized.isEmpty {
                return truncate(normalized, maxLength: 220)
            }
        }
        return nil
    }

    static func hookStringValue(_ rawValue: Any?) -> String? {
        guard let rawValue else { return nil }
        if rawValue is NSNull { return nil }
        if let value = rawValue as? String {
            return normalizedValue(value)
        }
        if let array = rawValue as? [Any] {
            let joined = array.compactMap(hookStringValue).joined(separator: " ")
            return normalizedValue(joined)
        }
        if let dict = rawValue as? [String: Any] {
            let joined = dict.keys.sorted().compactMap { hookStringValue(dict[$0]) }.joined(separator: " ")
            return normalizedValue(joined)
        }
        return normalizedValue(String(describing: rawValue))
    }

    static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = hookStringValue(object[key]) {
                return value
            }
        }
        return nil
    }

    static func normalizedValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    static func normalizedSingleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength - 3)) + "..."
    }
}
