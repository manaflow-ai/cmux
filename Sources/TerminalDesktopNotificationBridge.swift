import Darwin
import Foundation

enum TerminalDesktopNotificationBridge {
    static func resolvedTitle(actionTitle: String, fallbackTabTitle: String) -> String {
        actionTitle.isEmpty ? fallbackTabTitle : actionTitle
    }

    static func shouldSuppressNotification(
        claudeHooksEnabled: Bool,
        workspaceAgentPIDs: [String: pid_t],
        title: String,
        body: String
    ) -> Bool {
        guard claudeHooksEnabled else {
            return false
        }
        guard let claudePID = workspaceAgentPIDs["claude_code"], claudePID > 0 else {
            return false
        }
        return matchesClaudeAttentionDuplicate(title: title, body: body)
    }

    private static func matchesClaudeAttentionDuplicate(title: String, body: String) -> Bool {
        let normalizedTitle = normalizedText(title)
        let normalizedBody = normalizedText(body)
        if matchesGenericClaudeAttentionBanner(normalizedTitle) ||
            matchesGenericClaudeAttentionBanner(normalizedBody) {
            return true
        }
        return isGenericClaudeNotificationTitle(normalizedTitle) &&
            isGenericAttentionBody(normalizedBody)
    }

    private static func matchesGenericClaudeAttentionBanner(_ value: String) -> Bool {
        switch value {
        case "claude needs your attention",
             "claude needs your input",
             "claude code needs your attention",
             "claude code needs your input":
            return true
        default:
            return false
        }
    }

    private static func isGenericClaudeNotificationTitle(_ value: String) -> Bool {
        switch value {
        case "claude", "claude code":
            return true
        default:
            return false
        }
    }

    private static func isGenericAttentionBody(_ value: String) -> Bool {
        switch value {
        case "needs your attention", "needs your input":
            return true
        default:
            return false
        }
    }

    private static func normalizedText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
