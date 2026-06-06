import Foundation

enum AgentHibernationLifecycleState: String, Codable, Sendable, Equatable, CaseIterable {
    case unknown
    case running
    case idle
    case needsInput

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self.parse(rawValue) ?? .unknown
    }

    var allowsHibernation: Bool {
        self == .idle
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func parseCLIValue(_ rawValue: String) -> AgentHibernationLifecycleState? {
        parse(rawValue)
    }

    private static func parse(_ rawValue: String) -> AgentHibernationLifecycleState? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "unknown":
            return .unknown
        case "running":
            return .running
        case "idle":
            return .idle
        case "needsinput", "needs-input":
            return .needsInput
        default:
            return nil
        }
    }
}

enum AgentHibernationLifecycleStatusKeys {
    static let notificationTitleByStatusKey: [String: String] = [
        "amp": "Amp",
        "antigravity": "Antigravity",
        "claude_code": "Claude Code",
        "codebuddy": "CodeBuddy",
        "codex": "Codex",
        "copilot": "Copilot",
        "cursor": "Cursor",
        "factory": "Factory",
        "gemini": "Gemini",
        "grok": "Grok",
        "hermes-agent": "Hermes Agent",
        "kiro": "Kiro",
        "opencode": "OpenCode",
        "pi": "Pi",
        "qoder": "Qoder",
        "rovodev": "Rovo Dev",
    ]

    static let allowedStatusKeys: Set<String> = Set(notificationTitleByStatusKey.keys)

    static func isAllowed(_ key: String) -> Bool {
        allowedStatusKeys.contains(key)
    }

    static func statusKey(forNotificationTitle title: String) -> String? {
        statusKeyByNormalizedNotificationTitle[normalizedNotificationTitle(title)]
    }

    private static let statusKeyByNormalizedNotificationTitle: [String: String] = {
        var result: [String: String] = [:]
        var ambiguousTitles = Set<String>()
        for (statusKey, title) in notificationTitleByStatusKey {
            let normalized = normalizedNotificationTitle(title)
            guard !ambiguousTitles.contains(normalized) else { continue }
            if result[normalized] != nil {
                ambiguousTitles.insert(normalized)
                result.removeValue(forKey: normalized)
            } else {
                result[normalized] = statusKey
            }
        }
        return result
    }()

    private static func normalizedNotificationTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
