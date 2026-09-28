import AppKit
import Foundation

/// Direction of an agent turn jump.
enum AgentTurnNavigationDirection {
    case previous
    case next
}

extension TabManager {
    /// The turn rail model of the focused terminal, when it shows a rail.
    var focusedAgentTurnRailModel: AgentTurnRailModel? {
        guard let model = selectedTerminalPanel?.hostedView.agentTurnRailModel, model.isVisible else {
            return nil
        }
        return model
    }
}

extension AppDelegate {
    /// Shared path for the previous/next agent turn shortcut and palette
    /// commands: jumps the focused terminal's scrollback to the neighboring
    /// prompt of its Claude Code or Codex session.
    ///
    /// - Returns: `false`, so the key event keeps flowing to the terminal,
    ///   when the focused terminal has no agent turn rail.
    @discardableResult
    func performAgentTurnNavigation(
        _ direction: AgentTurnNavigationDirection,
        preferredWindow: NSWindow? = nil
    ) -> Bool {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        guard let model = activeTabManagerForCommands(preferredWindow: targetWindow)?
            .focusedAgentTurnRailModel else {
            return false
        }
        Task { @MainActor in
            let moved: Bool
            switch direction {
            case .previous:
                moved = await model.jumpToPreviousTurn()
            case .next:
                moved = await model.jumpToNextTurn()
            }
            if !moved { NSSound.beep() }
        }
        return true
    }
}
