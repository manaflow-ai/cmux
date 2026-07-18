/// The reason a topology stream cannot safely continue from its requested revision.
public enum TopologyResnapshotReason: String, Codable, Equatable, Sendable {
    /// The client named a daemon lifetime that is no longer current.
    case staleDaemon = "stale-daemon"

    /// The client named a persisted session that is no longer current.
    case staleSession = "stale-session"

    /// The client requested a revision newer than the daemon's current revision.
    case revisionAhead = "revision-ahead"

    /// The daemon no longer retains every delta needed to resume.
    case historyGap = "history-gap"

    /// The required replay exceeds the daemon's bounded replay limit.
    case replayTooLarge = "replay-too-large"

    /// The client consumed topology events too slowly to preserve continuity.
    case slowConsumer = "slow-consumer"
}
