import Foundation

struct AgentHibernationPanelState {
    let agent: SessionRestorableAgentSnapshot
    let hibernatedAt: Date
    let lastActivityAt: Date
    /// True when the user asked for this teardown (Sleep) rather than the
    /// routine idle/limit planner or critical memory pressure. Manual sleep is
    /// explicit-wake: the panel keeps showing the placeholder even once it
    /// becomes visible, where an automatically hibernated panel auto-resumes on
    /// visit. It is also excluded from the planner's live-terminal count so
    /// parking work by hand does not change how the automatic policy behaves.
    let isManual: Bool

    init(
        agent: SessionRestorableAgentSnapshot,
        hibernatedAt: Date,
        lastActivityAt: Date,
        isManual: Bool = false
    ) {
        self.agent = agent
        self.hibernatedAt = hibernatedAt
        self.lastActivityAt = lastActivityAt
        self.isManual = isManual
    }

    var agentDisplayName: String {
        agent.agentDisplayName
    }
}
