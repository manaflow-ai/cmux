/// What links an acpmux session to its surroundings, and its state, apart from what it does now:
/// its folder, the pull requests it opened, the chat that started it, the peer that owns it and
/// whether it works, waits or failed. These change a few times a turn; a working lane's step changes
/// many times a second (``AgentLaneStore/links(_:)``).
public nonisolated struct AgentLaneLinks: Hashable, Sendable {
    /// The session's working folder (its branch's pull request).
    public var cwd: String?
    /// The pull requests the session opened, as URLs.
    public var pullRequests: [String]
    /// The session that started this one.
    public var spawnedBy: String?
    /// The acpmux peer the lane is mirrored from; nil for this Mac's own.
    public var peer: String?
    /// The chat the session continues.
    public var chat: String?
    /// Working, waiting on you, idle, failed or lost (the session tree's roll-up).
    public var state: AgentActivityLane.State

    /// The links of `lane`.
    public init(_ lane: AgentActivityLane) {
        cwd = lane.cwd
        pullRequests = lane.pullRequests
        spawnedBy = lane.spawnedBy
        peer = lane.peer
        chat = lane.chat
        state = lane.state
    }
}
