import CMUXAgentLaunch
import Foundation

/// The shared mutation and label paths behind every session-priority control:
/// the SwiftUI and AppKit sidebar context menus and the command palette.
enum SessionPriorityActions {
    @MainActor
    static func applyDifficulty(_ difficulty: ClaudeSessionDifficulty?, to workspaces: [Workspace]) {
        for workspace in workspaces {
            workspace.setClaudeDifficultyOverride(difficulty)
        }
    }

    @MainActor
    static func setManual(_ on: Bool, for workspaces: [Workspace]) {
        for workspace in workspaces {
            workspace.setSessionPriorityManual(on)
        }
    }

    /// Auto (`nil`) first, then every difficulty.
    static let difficultyChoices: [ClaudeSessionDifficulty?] =
        [nil] + ClaudeSessionDifficulty.allCases.map { Optional($0) }

    static func difficultyTitle(_ difficulty: ClaudeSessionDifficulty?) -> String {
        switch difficulty {
        case nil: return String(localized: "contextMenu.claudeDifficulty.auto", defaultValue: "Auto")
        case .easy?: return String(localized: "sidebar.sessionPriority.difficulty.easy", defaultValue: "Easy")
        case .normal?: return String(localized: "sidebar.sessionPriority.difficulty.normal", defaultValue: "Normal")
        case .hard?: return String(localized: "sidebar.sessionPriority.difficulty.hard", defaultValue: "Hard")
        }
    }

    static var difficultyMenuTitle: String {
        String(localized: "contextMenu.claudeDifficulty", defaultValue: "Claude Difficulty")
    }

    /// The single flipping manual item's title.
    static func manualItemTitle(adjustableManual: Bool) -> String {
        adjustableManual
            ? String(
                localized: "contextMenu.sessionPriorityAdjustAutomatically",
                defaultValue: "Adjust Claude Effort Automatically"
            )
            : String(
                localized: "contextMenu.sessionPriorityManual",
                defaultValue: "Don't Adjust Claude Effort Here"
            )
    }
}

/// The session-priority values a sidebar row freezes for its context menu.
struct SessionPriorityMenuState: Equatable {
    var enabled = false
    var difficultyOverride: ClaudeSessionDifficulty?
    /// The workspace's manual flag is on, or cmux saw a `/effort` or `/model`
    /// on one of its panes. Both are lifted by "Adjust Claude Effort Automatically".
    var adjustableManual = false

    static let disabled = SessionPriorityMenuState()

    init(enabled: Bool = false, difficultyOverride: ClaudeSessionDifficulty? = nil, adjustableManual: Bool = false) {
        self.enabled = enabled
        self.difficultyOverride = difficultyOverride
        self.adjustableManual = adjustableManual
    }

    @MainActor
    init(workspace: Workspace) {
        // The override and manual flag are read even while the setting is off, so a
        // row frozen before the setting was turned on still carries them.
        enabled = SessionPriorityCoordinator.shared.isEnabled
        difficultyOverride = workspace.sessionPriorityState.difficultyOverride
        adjustableManual = workspace.sessionPriorityState.isManual
            || SessionPriorityCoordinator.shared.hasUserCommandOnScreen(in: workspace)
    }
}
