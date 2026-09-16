/// GitHub’s mergeability result, kept separate from CI checks.
public enum SidebarPullRequestMergeStatus: String, Sendable, Equatable {
    /// GitHub reports that the branch has no merge conflicts.
    case ready
    /// Repository rules, checks, draft state, or branch position block merging.
    case blocked
    /// GitHub reports a content conflict with the base branch.
    case conflict
    /// GitHub has not computed mergeability or the request failed.
    case unknown
}
