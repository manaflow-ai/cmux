import CmuxFoundation
import Foundation

extension AgentStatus {
    /// Maps one stored lifecycle state to the presentation status, or `nil` for
    /// `unknown`, which doubles as "no agent is running here" and must never win a
    /// reduction.
    init?(lifecycle: AgentHibernationLifecycleState) {
        switch lifecycle {
        case .error: self = .error
        case .needsInput: self = .needsInput
        case .running: self = .running
        case .idle: self = .idle
        case .unknown: return nil
        }
    }

    /// Reduces every agent reporting under one pane to the single presentation status
    /// that should drive both the pane border and the custom-sidebar row.
    ///
    /// Precedence is `error` > `needsInput` > `running` > `idle`. This deliberately
    /// differs from `Workspace.agentHibernationLifecycleState`, which ranks `running`
    /// first because it answers "is anything still working?" for hibernation. A border
    /// or sidebar row answers "does this pane want me?", so a blocked or errored agent
    /// has to win even while a sibling agent under another status key is still running —
    /// the Feed publishes exactly that shape, writing `needsInput` under
    /// `cmux.feed.attention:<agent>` while the agent's own key still reads `running`.
    ///
    /// Reserved `manual` / `manual:<id>` keys drive the sidebar loading spinner rather
    /// than an agent, so they are filtered out. An empty or unknown-only map resolves
    /// to `.none` (a plain terminal).
    static func resolve(lifecycles: [String: AgentHibernationLifecycleState]) -> AgentStatus {
        var winner: AgentStatus = .none
        for (key, lifecycle) in lifecycles {
            guard !AgentHibernationLifecycleStatusKeys.isManualKey(key) else { continue }
            guard let candidate = AgentStatus(lifecycle: lifecycle) else { continue }
            if candidate.attentionRank < winner.attentionRank {
                winner = candidate
            }
        }
        return winner
    }
}
