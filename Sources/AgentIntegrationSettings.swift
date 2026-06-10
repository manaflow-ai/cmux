import AppKit
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSocketControl
import CmuxSettings
import CmuxSettingsUI
import CmuxUpdaterUI
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers


// MARK: - Agent Integration Settings
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

enum KiroIntegrationSettings {
    enum NotificationLevel: String, CaseIterable, Identifiable {
        case minimal
        case standard
        case verbose

        var id: String { rawValue }

        var title: String {
            switch self {
            case .minimal:
                return String(localized: "settings.automation.kiro.notificationLevel.minimal", defaultValue: "Minimal")
            case .standard:
                return String(localized: "settings.automation.kiro.notificationLevel.standard", defaultValue: "Standard")
            case .verbose:
                return String(localized: "settings.automation.kiro.notificationLevel.verbose", defaultValue: "Verbose")
            }
        }
    }

    static let hooksEnabledKey = "kiroHooksEnabled"
    static let defaultHooksEnabled = true
    static let notificationLevelKey = "kiroNotificationLevel"
    static let defaultNotificationLevel = NotificationLevel.standard

    static func hooksEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hooksEnabledKey) == nil {
            return defaultHooksEnabled
        }
        return defaults.bool(forKey: hooksEnabledKey)
    }

    static func notificationLevel(defaults: UserDefaults = .standard) -> NotificationLevel {
        guard let raw = defaults.string(forKey: notificationLevelKey),
              let level = NotificationLevel(rawValue: raw) else {
            return defaultNotificationLevel
        }
        return level
    }
}

enum AmpIntegrationSettings {
    static let hooksEnabledKey = "ampHooksEnabled"
    static let defaultHooksEnabled = true

    static func hooksEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hooksEnabledKey) == nil {
            return defaultHooksEnabled
        }
        return defaults.bool(forKey: hooksEnabledKey)
    }
}

