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
    /// Each agent is reduced first: `error` > `needsInput` > `running` > `idle`.
    /// That keeps the Feed shape working — `cmux.feed.attention:<agent>` can
    /// outrank the same agent's `running` so a permission prompt still paints
    /// orange. Across agents, a `running` occupant wins: a leftover error from
    /// a previous agent in the same terminal must not paint the pane red over
    /// the one that is actually working.
    ///
    /// Reserved `manual` / `manual:<id>` keys drive the sidebar loading spinner rather
    /// than an agent, so they are filtered out. An empty or unknown-only map resolves
    /// to `.none` (a plain terminal).
    static func resolve(lifecycles: [String: AgentHibernationLifecycleState]) -> AgentStatus {
        var perAgent: [String: AgentStatus] = [:]
        for (key, lifecycle) in lifecycles {
            guard let owner = AgentHibernationLifecycleStatusKeys.owningAgent(for: key) else {
                continue
            }
            guard let candidate = AgentStatus(lifecycle: lifecycle) else { continue }
            let current = perAgent[owner] ?? .none
            if candidate.attentionRank < current.attentionRank {
                perAgent[owner] = candidate
            }
        }
        let statuses = Array(perAgent.values)
        if statuses.contains(.running) { return .running }
        return statuses.min { $0.attentionRank < $1.attentionRank } ?? .none
    }
}
