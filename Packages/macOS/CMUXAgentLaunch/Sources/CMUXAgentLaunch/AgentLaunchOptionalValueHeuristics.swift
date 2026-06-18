import Foundation

extension AgentLaunchSanitizer {
    static func looksLikeGreedyOptionalValue(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("-") else { return false }
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil { return true }
        return value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("./") || value.hasPrefix("../")
    }
}
