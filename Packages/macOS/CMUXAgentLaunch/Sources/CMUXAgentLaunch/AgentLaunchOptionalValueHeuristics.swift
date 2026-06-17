import Foundation

extension AgentLaunchSanitizer {
    static func looksLikeGreedyOptionalValue(_ value: String, following: String?) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("-") else { return false }
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil { return true }
        if following?.hasPrefix("-") == true { return true }
        return value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("./") || value.hasPrefix("../")
    }
}
