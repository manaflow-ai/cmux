public import Observation

/// Every acpmux session's lane (cx-v9k2f): this Mac's and the acpmux peers' it mirrors, from the
/// same `_acpmux/watch` as the turn states (`AgentTurnStateFeed`). The sidebar's Priority view,
/// Chief item and session tree read it.
@Observable @MainActor
public final class AgentLaneStore {
    public static let shared = AgentLaneStore()
    /// The Chief home's lanes (its subagents), apart from this Mac's own: the Priority view reads both.
    public static let chief = AgentLaneStore()

    /// Keyed by session id; empty while the watch is down.
    public var lanes: [String: AgentActivityLane] = [:]
    /// The acpmux socket whose watch fills the store (set by `AgentTurnStateFeed`), for requests
    /// about its sessions such as the Priority view's Archive.
    @ObservationIgnored public var socketPath: String?
    /// The watch is up and has delivered its page: `lanes` is every session, not a gap.
    public var live = false

    public init() {}
}
