import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

enum ClaudeCodeIntegrationSettings {
    static let hooksEnabledKey = "claudeCodeHooksEnabled"
    static let defaultHooksEnabled = true
    static let customClaudePathKey = "claudeCodeCustomClaudePath"

    static func hooksEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hooksEnabledKey) == nil {
            return defaultHooksEnabled
        }
        return defaults.bool(forKey: hooksEnabledKey)
    }

    static func customClaudePath(defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: customClaudePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

enum AgentSubagentNotificationSettings {
    static let suppressNotificationsKey = "suppressSubagentNotifications"
    static let defaultSuppressNotifications = true
    static let environmentKey = "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS"

    static func suppressNotifications(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: suppressNotificationsKey) == nil {
            return defaultSuppressNotifications
        }
        return defaults.bool(forKey: suppressNotificationsKey)
    }
}

enum CursorIntegrationSettings {
    static let hooksEnabledKey = "cursorHooksEnabled"
    static let defaultHooksEnabled = true

    static func hooksEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hooksEnabledKey) == nil {
            return defaultHooksEnabled
        }
        return defaults.bool(forKey: hooksEnabledKey)
    }
}

enum GeminiIntegrationSettings {
    static let hooksEnabledKey = "geminiHooksEnabled"
    static let defaultHooksEnabled = true

    static func hooksEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hooksEnabledKey) == nil {
            return defaultHooksEnabled
        }
        return defaults.bool(forKey: hooksEnabledKey)
    }
}

enum WelcomeSettings {
    static let shownKey = "cmuxWelcomeShown"
}
