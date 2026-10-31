import Observation

/// One session's slot in ``AgentLaneStore``: its lane and the lane's links, each observed on its
/// own, so a reader of one session is told about that session only.
@Observable @MainActor
final class AgentLaneCell {
    private(set) var lane: AgentActivityLane?
    /// Presence is separate from the lane value so structural readers can observe only
    /// session creation/purge, not every working/input/error transition.
    private(set) var hasLiveSession: Bool
    private(set) var links: AgentLaneLinks?

    init(_ lane: AgentActivityLane?) {
        self.lane = lane
        hasLiveSession = lane != nil
        links = lane.map(AgentLaneLinks.init)
    }

    /// Writes only what changed, so an unchanged lane notifies nobody.
    func update(_ new: AgentActivityLane?) {
        if hasLiveSession != (new != nil) { hasLiveSession = new != nil }
        if lane != new { lane = new }
        let newLinks = new.map(AgentLaneLinks.init)
        if links != newLinks { links = newLinks }
    }
}
