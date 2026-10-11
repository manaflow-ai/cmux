import Foundation

/// User initiated actions for a GitHub feed item. The app supplies the host
/// callback; the feed model never opens URLs or creates worktrees itself.
public nonisolated enum FeedGitHubAction: String, Sendable, Equatable, Hashable {
    case open
    case checkout
    case startAgent
    case approve
    case requestChanges
    case comment
}
