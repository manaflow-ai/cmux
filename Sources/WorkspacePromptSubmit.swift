import CMUXAgentLaunch
import Foundation

enum IMessageModeSettings {
    static let key = "app.iMessageMode"
    static let defaultValue = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

/// Per-workspace-group behavior knobs for sidebar iMessage mode.
///
/// - `sortInsideGroups` (default true): when iMessage mode floats workspaces
///   by latest unread, members within a group sort by unread while the group
///   section position stays put.
/// - `floatGroups` (default false): when true, the group section itself
///   reorders by its most-recent unread member.
///
/// Both knobs are persisted to UserDefaults via the keys below and mirrored
/// in `~/.config/cmux/cmux.json` under `sidebar.imessageMode.*`. The sort
/// path treats the current build as passthrough until the broader iMessage
/// sort logic exists; the knobs land here so user-set values survive the
/// upgrade that activates the behavior.
enum IMessageModeGroupSortSettings {
    static let sortInsideGroupsKey = "app.iMessageMode.sortInsideGroups"
    static let floatGroupsKey = "app.iMessageMode.floatGroups"
    static let sortInsideGroupsDefault = true
    static let floatGroupsDefault = false

    static func sortInsideGroups(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: sortInsideGroupsKey) == nil {
            return sortInsideGroupsDefault
        }
        return defaults.bool(forKey: sortInsideGroupsKey)
    }

    static func floatGroups(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: floatGroupsKey) == nil {
            return floatGroupsDefault
        }
        return defaults.bool(forKey: floatGroupsKey)
    }

    static func setSortInsideGroups(_ value: Bool, defaults: UserDefaults = .standard) {
        if value == sortInsideGroupsDefault {
            defaults.removeObject(forKey: sortInsideGroupsKey)
        } else {
            defaults.set(value, forKey: sortInsideGroupsKey)
        }
    }

    static func setFloatGroups(_ value: Bool, defaults: UserDefaults = .standard) {
        if value == floatGroupsDefault {
            defaults.removeObject(forKey: floatGroupsKey)
        } else {
            defaults.set(value, forKey: floatGroupsKey)
        }
    }
}

extension WorkstreamEvent {
    var submittedPromptMessage: String? {
        guard hookEventName == .userPromptSubmit else { return nil }
        let contextMessage = context?.lastUserMessage.flatMap(Self.normalizedPromptText)
        return Self.messageText(fromJSON: toolInputJSON, keys: Self.promptMessageKeys)
            ?? contextMessage
            ?? Self.messageText(fromJSON: extraFieldsJSON, keys: Self.promptMessageKeys)
    }

    /// Original Unicode extended grapheme cluster count (Swift `String.count`).
    ///
    /// `submittedPromptMessage` is capped at 240 characters by the CLI before
    /// it reaches us, so counting it measures the cap rather than the prompt.
    /// The CLI publishes `<key>_length` beside each truncated message key;
    /// this resolves it with the same precedence the message itself uses.
    var submittedPromptLength: Int? {
        guard hookEventName == .userPromptSubmit else { return nil }
        if let candidate = Self.messageLength(fromJSON: toolInputJSON) { return candidate.length }
        if Self.messageText(fromJSON: toolInputJSON, keys: Self.promptMessageKeys) != nil { return nil }
        // A context-only message has no original-size evidence. Do not borrow
        // a different message's count from the lower-priority extra fields.
        if context?.lastUserMessage.flatMap(Self.normalizedPromptText) != nil { return nil }
        return Self.messageLength(fromJSON: extraFieldsJSON)?.length
    }

    var assistantFinalMessage: String? {
        guard hookEventName == .stop else { return nil }
        let contextMessage = context?.assistantPreamble.flatMap(Self.normalizedPromptText)
        return contextMessage
            ?? Self.messageText(fromJSON: extraFieldsJSON, keys: Self.assistantMessageKeys)
            ?? Self.messageText(fromJSON: toolInputJSON, keys: Self.assistantMessageKeys)
    }

    private static let promptMessageKeys = ["prompt", "text", "message", "body"]
    private static let assistantMessageKeys = [
        "last_assistant_message",
        "lastAssistantMessage",
        "assistantPreamble",
        "assistant_preamble",
        "last_agent_message",
        "lastAgentMessage",
    ]

    private struct PromptLengthCandidate { let length: Int? }

    /// A present message without valid metadata stops fallback to another message.
    private static func messageLength(fromJSON jsonString: String?) -> PromptLengthCandidate? {
        guard let jsonString,
              let data = jsonString.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let containers = [dict] + ["notification", "data"].compactMap { dict[$0] as? [String: Any] }
        for container in containers {
            for key in promptMessageKeys where (container[key] as? String).flatMap(normalizedPromptText) != nil {
                return PromptLengthCandidate(length: validatedPromptLength(container["\(key)_length"]))
            }
        }
        for container in containers {
            for key in promptMessageKeys where container[key] is String || container["\(key)_length"] != nil {
                return PromptLengthCandidate(length: validatedPromptLength(container["\(key)_length"]))
            }
        }
        return nil
    }

    private static func validatedPromptLength(_ value: Any?) -> Int? {
        // Match the CLI's 1 MiB stdin ceiling. Reject Boolean NSNumber bridging,
        // fractional values, strings, negatives, and unsafe/out-of-range numbers.
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let length = Int(exactly: number.doubleValue),
              (0...1_048_576).contains(length) else { return nil }
        return length
    }

    private static func messageText(fromJSON jsonString: String?, keys: [String]) -> String? {
        guard let jsonString else { return nil }
        guard let data = jsonString.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return normalizedPromptText(jsonString)
        }

        if let string = value as? String {
            return normalizedPromptText(string)
        }
        guard let dict = value as? [String: Any] else { return nil }
        return messageText(from: dict, keys: keys)
    }

    private static func messageText(from dict: [String: Any], keys: [String]) -> String? {
        if let direct = firstMessageString(in: dict, keys: keys) {
            return direct
        }
        for key in ["notification", "data"] {
            if let nested = dict[key] as? [String: Any],
               let nestedMessage = firstMessageString(in: nested, keys: keys) {
                return nestedMessage
            }
        }
        return nil
    }

    private static func firstMessageString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dict[key] as? String,
                  let normalized = normalizedPromptText(value) else { continue }
            return normalized
        }
        return nil
    }

    private static func normalizedPromptText(_ value: String) -> String? {
        let normalized = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

extension TabManager {
    private enum ConversationMessageKind {
        case promptSubmission
        case assistantFinal
    }

    @discardableResult
    func handlePromptSubmit(
        workspaceId: UUID,
        message: String?,
        submittedLength: Int? = nil,
        iMessageModeEnabled: Bool = IMessageModeSettings.isEnabled()
    ) -> (messageRecorded: Bool, reordered: Bool, index: Int)? {
        handleConversationMessage(
            workspaceId: workspaceId,
            message: message,
            submittedLength: submittedLength,
            iMessageModeEnabled: iMessageModeEnabled,
            kind: .promptSubmission,
            reorderWithoutMessage: true
        )
    }

    @discardableResult
    func handleAssistantFinalMessage(
        workspaceId: UUID,
        message: String?,
        iMessageModeEnabled: Bool = IMessageModeSettings.isEnabled()
    ) -> (messageRecorded: Bool, reordered: Bool, index: Int)? {
        handleConversationMessage(
            workspaceId: workspaceId,
            message: message,
            iMessageModeEnabled: iMessageModeEnabled,
            kind: .assistantFinal,
            reorderWithoutMessage: false
        )
    }

    private func handleConversationMessage(
        workspaceId: UUID,
        message: String?,
        submittedLength: Int? = nil,
        iMessageModeEnabled: Bool,
        kind: ConversationMessageKind,
        reorderWithoutMessage: Bool
    ) -> (messageRecorded: Bool, reordered: Bool, index: Int)? {
        guard let originalIndex = tabs.firstIndex(where: { $0.id == workspaceId }) else {
            return nil
        }

        let workspace = tabs[originalIndex]
        let hasMessage = Workspace.conversationMessagePreview(from: message) != nil
        let messageRecorded: Bool
        switch kind {
        case .promptSubmission:
            messageRecorded = workspace.recordSubmittedMessage(message)
            if messageRecorded {
                CmuxEventBus.shared.publishWorkspacePromptSubmitted(
                    workspaceId: workspaceId,
                    message: message,
                    preview: Workspace.conversationMessagePreview(from: message),
                    submittedLength: submittedLength
                )
            }
        case .assistantFinal:
            guard iMessageModeEnabled else {
                return (false, false, originalIndex)
            }
            messageRecorded = workspace.recordConversationMessage(message)
        }
        guard iMessageModeEnabled else {
            return (messageRecorded, false, originalIndex)
        }
        guard messageRecorded || reorderWithoutMessage || hasMessage else {
            return (messageRecorded, false, originalIndex)
        }
        moveTabToTop(workspaceId)
        let newIndex = tabs.firstIndex(where: { $0.id == workspaceId }) ?? originalIndex
        return (messageRecorded, newIndex != originalIndex, newIndex)
    }
}

extension Workspace {
    static func conversationMessagePreview(from message: String?, maxLength: Int = 240) -> String? {
        guard let message else { return nil }
        let collapsed = message
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxLength else { return collapsed }
        return "\(collapsed.prefix(maxLength))..."
    }
}
