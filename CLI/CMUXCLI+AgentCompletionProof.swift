import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    private static let completionStallClassifier = AgentStallClassifier()

    /// Returns true only when Claude's Stop payload contains a usable assistant
    /// message that is not itself a known provider-failure banner. Claude Code
    /// normally sends `last_assistant_message` for a successful turn, but some
    /// provider refusals and quota responses are echoed there as well. Treating
    /// those strings as a normal completion would suppress the PTY classifier
    /// at precisely the boundary where it needs to act.
    func claudeHookProvesNormalCompletion(
        assistantMessage: String?,
        payload: [String: Any]?
    ) -> Bool {
        hookProvesNormalCompletion(
            provider: "claude",
            assistantMessage: assistantMessage,
            payload: payload
        )
    }

    /// Returns true only when a Codex stop payload proves a healthy assistant
    /// response. Codex can echo a safeguard or quota banner as
    /// `last_assistant_message` without emitting a transcript `error` event,
    /// so the same conservative proof used for Claude is required before the
    /// app suppresses PTY classification.
    func codexHookProvesNormalCompletion(
        assistantMessage: String?,
        payload: [String: Any]?
    ) -> Bool {
        hookProvesNormalCompletion(
            provider: "codex",
            assistantMessage: assistantMessage,
            payload: payload
        )
    }

    private func hookProvesNormalCompletion(
        provider: String,
        assistantMessage: String?,
        payload: [String: Any]?
    ) -> Bool {
        guard let assistantMessage,
              !normalizedSingleLine(assistantMessage).isEmpty else {
            return false
        }
        let hasStructuredFailure = hookPayloadContainsStructuredFailure(payload)
        guard !hasStructuredFailure else { return false }
        return Self.completionStallClassifier.classify(
            provider: provider,
            output: assistantMessage,
            hasStructuredEvidence: hasStructuredFailure
        ) == nil
    }

    private func hookPayloadContainsStructuredFailure(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let normalizedKey = key
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .lowercased()
                if [
                    "error", "errorcode", "iserror", "failure", "failurecode",
                    "codexerrorinfo",
                ].contains(normalizedKey),
                   hookStructuredFailureValueIsPresent(child) {
                    return true
                }
                if hookPayloadContainsStructuredFailure(child) {
                    return true
                }
            }
            return false
        }
        if let array = value as? [Any] {
            return array.contains { hookPayloadContainsStructuredFailure($0) }
        }
        return false
    }

    private func hookStructuredFailureValueIsPresent(_ value: Any) -> Bool {
        if value is NSNull { return false }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue || number.intValue != 0 }
        if let string = value as? String {
            let normalized = normalizedSingleLine(string).lowercased()
            return !normalized.isEmpty
                && !["false", "null", "none", "0", "ok", "success"].contains(normalized)
        }
        if let dictionary = value as? [String: Any] { return !dictionary.isEmpty }
        if let array = value as? [Any] { return !array.isEmpty }
        return true
    }
}
