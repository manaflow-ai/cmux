import CmuxFoundation
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

    /// Settings key overriding the pane border color for one agent state.
    ///
    /// Flat keys rather than a nested object so they parse, validate, and
    /// round-trip through `cmux.json` exactly like the sibling pane colors.
    static func agentStateColorKey(for status: AgentStatus) -> String {
        switch status {
        case .running: "agentStateColorRunning"
        case .idle: "agentStateColorIdle"
        case .needsInput: "agentStateColorNeedsInput"
        case .error: "agentStateColorError"
        case .none: "agentStateColorNoAgent"
        }
    }

    static let agentStateColorKeys = AgentStatus.allCases.map(agentStateColorKey(for:))

    /// The built-in color for one state: the shared `AgentStatus` palette, or
    /// the border-local neutral for a pane with no agent.
    static func defaultAgentStateColorHex(for status: AgentStatus) -> String {
        status.tintHex ?? noAgentPaneBorderHex
    }

    /// The color a pane in `status` should draw, honoring a user override.
    ///
    /// An override that is not strict `#RRGGBB` is ignored rather than being
    /// allowed through: `WorkspaceAttentionColor` silently falls back to the
    /// notification-ring accent for anything it cannot parse, which would read
    /// as the unread blue and look like the state was simply wrong.
    static func agentStateColorHex(
        for status: AgentStatus,
        defaults: UserDefaults = .standard
    ) -> String {
        normalizedColorHex(defaults.string(forKey: agentStateColorKey(for: status)))
            ?? defaultAgentStateColorHex(for: status)
    }

    private static func normalizedColorHex(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        return WorkspaceTabColorSettings.normalizedHex(rawValue)
    }
}
