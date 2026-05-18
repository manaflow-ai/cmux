import CMUXWorkstream
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

extension WorkstreamEvent {
    var submittedPromptMessage: String? {
        guard hookEventName == .userPromptSubmit else { return nil }
        let contextMessage = context?.lastUserMessage.flatMap(Self.normalizedPromptText)
        return Self.messageText(fromJSON: toolInputJSON, keys: Self.promptMessageKeys)
            ?? contextMessage
            ?? Self.messageText(fromJSON: extraFieldsJSON, keys: Self.promptMessageKeys)
    }

    var assistantFinalMessage: String? {
        guard hookEventName == .stop || hookEventName == .subagentStop else { return nil }
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
    @discardableResult
    func handlePromptSubmit(
        workspaceId: UUID,
        message: String?,
        iMessageModeEnabled: Bool = IMessageModeSettings.isEnabled()
    ) -> (messageRecorded: Bool, reordered: Bool, index: Int)? {
        handleConversationMessage(
            workspaceId: workspaceId,
            message: message,
            iMessageModeEnabled: iMessageModeEnabled,
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
            reorderWithoutMessage: false
        )
    }

    private func handleConversationMessage(
        workspaceId: UUID,
        message: String?,
        iMessageModeEnabled: Bool,
        reorderWithoutMessage: Bool
    ) -> (messageRecorded: Bool, reordered: Bool, index: Int)? {
        guard let originalIndex = tabs.firstIndex(where: { $0.id == workspaceId }) else {
            return nil
        }
        guard iMessageModeEnabled else {
            return (false, false, originalIndex)
        }

        let workspace = tabs[originalIndex]
        let hasMessage = Workspace.conversationMessagePreview(from: message) != nil
        let messageRecorded = workspace.recordConversationMessage(message)
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
