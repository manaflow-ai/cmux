import CmuxNextAgentActivity
import Observation

/// Every acpmux session's lane (cx-v9k2f): this Mac's and the acpmux peers' it mirrors, from the
/// same `_acpmux/watch` as the turn states (``AgentTurnStateFeed``). The lanes view on the Agent
/// Activity page and the sidebar's Lanes item read it.
@Observable @MainActor
final class AgentLaneStore {
    static let shared = AgentLaneStore()

    /// Keyed by session id; empty while the watch is down.
    var lanes: [String: AgentActivityLane] = [:]

    /// Sessions a person should look at: waiting on them, failed or lost.
    var attentionCount: Int { lanes.values.count(where: \.needsAttention) }

    /// The lanes in a stable order for the page (it groups and sorts them itself).
    var sorted: [AgentActivityLane] { lanes.values.sorted { $0.id < $1.id } }
}
