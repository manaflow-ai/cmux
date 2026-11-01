import CMUXAgentLaunch
import CmuxSidebar
import Foundation

/// What one Claude pane's session priority looks like right now.
enum SessionPriorityPaneState: Equatable {
    case upToDate
    case applying
    case held(SessionPriorityApplyGate.HoldReason)
    case notApplied(SessionPriorityApplyResult.Refusal?)
    case manual(SessionPriorityManualSignal)

    /// Whether cmux leaves every one of these panes alone, so their workspace's target applies to
    /// none of them. `false` for no panes.
    static func allLeftAlone(_ states: [SessionPriorityPaneState]) -> Bool {
        !states.isEmpty && states.allSatisfy {
            if case .manual = $0 { return true }
            return false
        }
    }

    /// Higher is shown in preference to lower.
    fileprivate var severity: Int {
        switch self {
        case .manual: return 4
        case .notApplied: return 3
        case .held: return 2
        case .applying: return 1
        case .upToDate: return 0
        }
    }
}

/// The one sidebar row per workspace that shows its tier, difficulty, target and state.
enum SessionPriorityStatusRow {
    static let key = "session_priority"
    /// Above an agent's ordinary status line and program status (priority 0 to 4), so the row
    /// stays among the three lines a collapsed workspace row shows next to two `set-status
    /// --priority 200` lines; below an agent line that asks for attention (needs input or an
    /// error, priority 100), which it never hides.
    static let priority = 50

    /// The row for a workspace in the plan. The effort segment is left out when no pane takes
    /// `target` (every pane is left alone), as the CLI's snapshot reports no target then.
    static func entry(
        tier: SessionPriorityTier,
        difficulty: ClaudeSessionDifficulty,
        difficultySource: SessionPriorityWorkspaceState.DifficultySource,
        target: SessionPriorityTarget?,
        paneStates: [SessionPriorityPaneState]
    ) -> SidebarStatusEntry {
        var segments = [tierName(tier), difficultyText(difficulty, source: difficultySource)]
        if let target, !SessionPriorityPaneState.allLeftAlone(paneStates), let effortText = targetText(target) {
            segments.append(effortText)
        }
        if let state = paneStates.max(by: { $0.severity < $1.severity }) {
            segments.append(stateText(state))
        }
        return SidebarStatusEntry(
            key: key,
            value: segments.joined(separator: " · "),
            // A hare and a tortoise; `bolt.fill` is the running agent's own status icon.
            icon: tier == .urgent ? "hare.fill" : "tortoise.fill",
            priority: priority
        )
    }

    private static func tierName(_ tier: SessionPriorityTier) -> String {
        switch tier {
        case .urgent: return String(localized: "sidebar.sessionPriority.tier.urgent", defaultValue: "Urgent")
        case .slow: return String(localized: "sidebar.sessionPriority.tier.slow", defaultValue: "Slow")
        }
    }

    private static func difficultyName(_ difficulty: ClaudeSessionDifficulty) -> String {
        switch difficulty {
        case .easy: return String(localized: "sidebar.sessionPriority.difficulty.easy", defaultValue: "Easy")
        case .normal: return String(localized: "sidebar.sessionPriority.difficulty.normal", defaultValue: "Normal")
        case .hard: return String(localized: "sidebar.sessionPriority.difficulty.hard", defaultValue: "Hard")
        }
    }

    private static func difficultyText(
        _ difficulty: ClaudeSessionDifficulty,
        source: SessionPriorityWorkspaceState.DifficultySource
    ) -> String {
        let name = difficultyName(difficulty)
        switch source {
        case .override:
            return String(
                format: String(localized: "sidebar.sessionPriority.difficulty.manual", defaultValue: "%@ (manual)"),
                locale: .current,
                name
            )
        case .auto:
            return String(
                format: String(localized: "sidebar.sessionPriority.difficulty.auto", defaultValue: "%@ (auto)"),
                locale: .current,
                name
            )
        case .default:
            return name
        }
    }

    /// Effort and model are technical identifiers, shown as they are. `nil` for an empty target.
    static func targetText(_ target: SessionPriorityTarget) -> String? {
        switch (target.effort, target.model) {
        case let (effort?, model?): return "\(effort.rawValue) / \(model)"
        case let (effort?, nil): return effort.rawValue
        case let (nil, model?): return model
        case (nil, nil): return nil
        }
    }

    private static func stateText(_ state: SessionPriorityPaneState) -> String {
        switch state {
        case .upToDate: return String(localized: "sidebar.sessionPriority.state.upToDate", defaultValue: "applied")
        case .applying: return String(localized: "sidebar.sessionPriority.state.applying", defaultValue: "applying…")
        case .held: return String(localized: "sidebar.sessionPriority.state.held", defaultValue: "waiting for an idle prompt")
        case .notApplied: return String(localized: "sidebar.sessionPriority.state.notApplied", defaultValue: "not applied")
        case .manual: return String(localized: "sidebar.sessionPriority.state.manual", defaultValue: "not adjusted")
        }
    }
}
