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
    /// The chat key is stable while a turn runs, so history readers can observe it without
    /// subscribing to the lane's working/input transitions.
    private(set) var chat: String?

    init(_ lane: AgentActivityLane?) {
        self.lane = lane
        hasLiveSession = lane != nil
        links = lane.map(AgentLaneLinks.init)
        chat = lane?.chat
    }

    /// Writes only what changed, so an unchanged lane notifies nobody.
    func update(_ new: AgentActivityLane?) {
        if hasLiveSession != (new != nil) { hasLiveSession = new != nil }
        if lane != new { lane = new }
        let newLinks = new.map(AgentLaneLinks.init)
        if links != newLinks { links = newLinks }
        let newChat = new?.chat
        if chat != newChat { chat = newChat }
    }
}
