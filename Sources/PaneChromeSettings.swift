import Foundation

enum PaneChromeSettings {
    static let paneBorderColorKey = "paneBorderColor"
    static let activePaneBorderColorKey = "activePaneBorderColor"
    static let agentStateBorderKey = "agentStateBorder"
    static let defaultColorHex = ""
    static let activeBorderLineWidth = 2.0
    static let defaultAgentStateBorderEnabled = true
    static let didChangeNotification = Notification.Name("cmux.paneChromeSettingsDidChange")

    static func paneBorderColorHex(defaults: UserDefaults = .standard) -> String? {
        normalizedColorHex(defaults.string(forKey: Self.paneBorderColorKey))
    }

    static func activePaneBorderColorHex(defaults: UserDefaults = .standard) -> String? {
        normalizedColorHex(defaults.string(forKey: Self.activePaneBorderColorKey))
    }

    static func isAgentStateBorderEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: Self.agentStateBorderKey) != nil else {
            return defaultAgentStateBorderEnabled
        }
        return defaults.bool(forKey: Self.agentStateBorderKey)
    }

    static func resolvedPaneBorderHex(configuredHex: String?, fallback: String) -> String {
        normalizedColorHex(configuredHex) ?? fallback
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: Self.didChangeNotification, object: nil)
    }

    /// Border color for a pane with no agent reporting: a plain terminal. The
    /// active agent-status palette lives on `AgentStatus.tintHex` in
    /// CmuxFoundation; this is only the border-local no-agent neutral.
    static let noAgentPaneBorderHex = "#000000"

    private static func normalizedColorHex(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        return WorkspaceTabColorSettings.normalizedHex(rawValue)
    }
}
