import Observation

/// One session's slot in ``AgentLaneStore``: its lane and the lane's links, each observed on its
/// own, so a reader of one session is told about that session only.
@Observable @MainActor
final class AgentLaneCell {
    private(set) var lane: AgentActivityLane?
    private(set) var links: AgentLaneLinks?

    init(_ lane: AgentActivityLane?) {
        self.lane = lane
        links = lane.map(AgentLaneLinks.init)
    }

    /// Writes only what changed, so an unchanged lane notifies nobody.
    func update(_ new: AgentActivityLane?) {
        if lane != new { lane = new }
        let newLinks = new.map(AgentLaneLinks.init)
        if links != newLinks { links = newLinks }
    }
}
