import CmuxNextCompat
import CmuxNextDesign
public import Observation

/// Every acpmux session's lane (cx-v9k2f): this Mac's and the acpmux peers' it mirrors, from the
/// same `_acpmux/watch` as the turn states (`AgentTurnStateFeed`). The lanes view on the
/// Agent Activity page and the sidebar's Lanes item read it.
@Observable @MainActor
public final class AgentLaneStore {
    public static let shared = AgentLaneStore()

    /// Keyed by session id; empty while the watch is down.
    public var lanes: [String: AgentActivityLane] = [:]

    public init() {}

    /// Shown sessions a person should look at: waiting on them, failed or lost.
    public var attentionCount: Int { shown.count(where: \.needsAttention) }

    /// The lanes the sidebar item and the lanes view show, in a stable order (the page groups and
    /// sorts them itself): this Mac's own sessions (no peer, no coordinator), or every lane while
    /// `AgentActivityTunables.lanesShowFleet` is on. Reading it observes the toggle too.
    public var shown: [AgentActivityLane] {
        let fleet = AgentActivityTunables.lanesShowFleet.value
        return lanes.values.filter { fleet || ($0.peer == nil && $0.parent == nil) }.sorted { $0.id < $1.id }
    }
}

extension AgentActivityModel {
    /// Shows `store`'s lanes while `enabled` (Labs preview features: off by default until the
    /// lanes view is styled), else none.
    public func follow(_ store: AgentLaneStore, while enabled: @escaping @MainActor @Sendable () -> Bool) -> Task<Void, Never> {
        // task-owner: the caller (the page tab cancels it in `close`); event-driven (Observation)
        Task { [weak self] in
            for await value in ObservationStream({ enabled() ? store.shown : nil }) {
                guard let self else { return }
                lanes = value
            }
        }
    }
}
