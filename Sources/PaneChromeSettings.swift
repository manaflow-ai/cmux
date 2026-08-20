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

    private static func normalizedColorHex(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        return WorkspaceTabColorSettings.normalizedHex(rawValue)
    }
}

/// The agent lifecycle states that tint a terminal pane's border.
///
/// `unknown` deliberately has no case: it doubles as "no agent is running in
/// this pane" (`Workspace.agentHibernationLifecycleState` falls back to it for
/// an empty map), so an unknown lifecycle must never color a pane.
///
/// Mirrors `SidebarStateIndicatorState` from the in-flight sidebar
/// state-indicator work so the two palettes can converge on one type.
enum AgentPaneState: String, CaseIterable, Sendable, Equatable {
    /// The agent is blocked waiting on user input.
    case needsInput
    /// The agent is actively working.
    case running
    /// The agent finished its turn.
    case idle

    /// Sort rank backing the reduction below; lower ranks win.
    fileprivate var precedenceRank: Int {
        switch self {
        case .needsInput: 0
        case .running: 1
        case .idle: 2
        }
    }
}

/// Resolves one pane's agent lifecycle states into a single border color.
enum AgentPaneStateBorder {
    // The palette matches the sidebar's agent status rows, so a pane and its
    // sidebar row read as the same signal. These are the rendered sidebar
    // colors rather than the raw `set_status --color` hexes the CLI hooks
    // emit, which the sidebar does not display verbatim.

    /// Hex color for a pane whose agent is blocked on the user (sidebar INPUT).
    static let needsInputHex = "#EFA237"
    /// Hex color for a pane whose agent is working (sidebar WORKING).
    static let runningHex = "#4385F8"
    /// Hex color for a pane whose agent finished its turn (sidebar READY).
    static let idleHex = "#6DCE63"

    /// Collapses every agent reporting under `panelId` into the one state that
    /// should drive the border.
    ///
    /// Precedence is `needsInput` > `running` > `idle`. This deliberately
    /// differs from `Workspace.agentHibernationLifecycleState`, which ranks
    /// `running` first because it answers "is anything still working?" for
    /// hibernation. A border answers "does this pane want me?", so a blocked
    /// agent has to win even while a sibling agent under another status key is
    /// still running — the Feed publishes exactly that shape, writing
    /// `needsInput` under `cmux.feed.attention:<agent>` while the agent's own
    /// key still reads `running`.
    ///
    /// Reserved `manual` / `manual:<id>` keys drive the sidebar loading spinner
    /// rather than an agent, so they are filtered out.
    static func state(
        lifecycles: [String: AgentHibernationLifecycleState]
    ) -> AgentPaneState? {
        var winner: AgentPaneState?
        for (key, lifecycle) in lifecycles {
            guard !AgentHibernationLifecycleStatusKeys.isManualKey(key) else { continue }
            guard let candidate = Self.paneState(for: lifecycle) else { continue }
            if let current = winner, current.precedenceRank <= candidate.precedenceRank {
                continue
            }
            winner = candidate
        }
        return winner
    }

    /// The border color for a resolved state, or `nil` when no agent state
    /// should color the pane.
    static func colorHex(
        lifecycles: [String: AgentHibernationLifecycleState]
    ) -> String? {
        state(lifecycles: lifecycles).map(Self.colorHex(for:))
    }

    static func colorHex(for state: AgentPaneState) -> String {
        switch state {
        case .needsInput: needsInputHex
        case .running: runningHex
        case .idle: idleHex
        }
    }

    private static func paneState(
        for lifecycle: AgentHibernationLifecycleState
    ) -> AgentPaneState? {
        switch lifecycle {
        case .needsInput: .needsInput
        case .running: .running
        case .idle: .idle
        case .unknown: nil
        }
    }
}
