import Foundation

enum ClaudeNotificationTypeNormalization {
    static let ignoredTypesDefaultsKey = "claudeCodeIgnoredNotificationTypes"
    static let ignoredTypesEnvironmentKey = "CMUX_CLAUDE_IGNORED_NOTIFICATION_TYPES"
    static let defaultIgnoredTypes: [String] = []

    static func normalized(_ raw: String) -> String? {
        let collapsedWhitespace = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let normalized = collapsedWhitespace
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedSet(_ values: [String]) -> Set<String> {
        Set(values.compactMap(normalized))
    }

    static func normalizedUniqueList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            guard let normalized = normalized(raw),
                  seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }
}
