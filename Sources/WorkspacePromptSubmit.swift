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
        return Self.promptText(fromJSON: toolInputJSON)
            ?? contextMessage
            ?? Self.promptText(fromJSON: extraFieldsJSON)
    }

    private static func promptText(fromJSON jsonString: String?) -> String? {
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
        return promptText(from: dict)
    }

    private static func promptText(from dict: [String: Any]) -> String? {
        if let direct = firstPromptString(in: dict, keys: ["prompt", "text", "message", "body"]) {
            return direct
        }
        for key in ["notification", "data"] {
            if let nested = dict[key] as? [String: Any],
               let nestedPrompt = firstPromptString(in: nested, keys: ["prompt", "text", "message", "body"]) {
                return nestedPrompt
            }
        }
        return nil
    }

    private static func firstPromptString(in dict: [String: Any], keys: [String]) -> String? {
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
        guard let originalIndex = tabs.firstIndex(where: { $0.id == workspaceId }) else {
            return nil
        }
        guard iMessageModeEnabled else {
            return (false, false, originalIndex)
        }

        let workspace = tabs[originalIndex]
        let messageRecorded = workspace.recordSubmittedMessage(message)
        moveTabToTop(workspaceId)
        let newIndex = tabs.firstIndex(where: { $0.id == workspaceId }) ?? originalIndex
        return (messageRecorded, newIndex != originalIndex, newIndex)
    }
}

extension Workspace {
    static func submittedMessagePreview(from message: String?, maxLength: Int = 240) -> String? {
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
