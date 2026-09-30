import Foundation

/// The agent a terminal pane's Stop button interrupts, and how.
///
/// Only agents whose interrupt is a single Escape are listed. The button
/// shows only while the pane's journaled lifecycle says one of them is
/// running, the same gate the TextBox uses before sending Escape.
enum AgentTurnInterruptTarget: String, CaseIterable, Equatable, Sendable {
    case claudeCode = "claude_code"
    case codex

    /// Sidebar lifecycle key.
    var statusKey: String { rawValue }

    /// Agent slug its hooks journal under.
    var hookSource: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Whether cmux journals the interrupt so the pane leaves `running`.
    /// Only Claude Code: it runs no Stop hook on interrupt, and its next
    /// PreToolUse declares the pane running again if the turn continues.
    /// Codex journals lifecycle only at prompt submit and Stop, so a settle
    /// could mark a still-working Codex pane idle for the rest of the turn.
    var settlesTurnInJournal: Bool { self == .claudeCode }

    /// Named keys that interrupt the running turn.
    var interruptKeys: [TextBoxTerminalKey] { [.escape] }

    /// The unambiguous running agent on a pane, or `nil` when none is running
    /// or multiple agents claim the pane without foreground ownership proof.
    static func resolve(
        statusKeyedStates: [String: AgentHibernationLifecycleState],
        foregroundStatusKey: String? = nil
    ) -> AgentTurnInterruptTarget? {
        let runningKeys = statusKeyedStates.compactMap { key, state in
            state == .running ? key : nil
        }
        if runningKeys.count == 1 {
            guard let key = runningKeys.first,
                  foregroundStatusKey == nil || foregroundStatusKey == key else { return nil }
            return allCases.first { $0.statusKey == key }
        }
        guard let foregroundStatusKey,
              runningKeys.contains(foregroundStatusKey) else { return nil }
        return allCases.first { $0.statusKey == foregroundStatusKey }
    }
}
