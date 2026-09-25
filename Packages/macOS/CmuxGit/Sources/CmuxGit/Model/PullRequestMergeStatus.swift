/// GitHub’s mergeability result, kept separate from CI checks.
public enum PullRequestMergeStatus: String, Sendable, Equatable {
    /// GitHub reports that the branch has no merge conflicts.
    case ready
    /// Repository rules, checks, draft state, or branch position block merging.
    case blocked
    /// GitHub reports a content conflict with the base branch.
    case conflict
    /// GitHub has not computed mergeability or the request failed.
    case unknown

    /// Maps GitHub’s nullable mergeability and separate repository-policy result.
    public init(mergeable: Bool?, mergeableState: String?) {
        if mergeable == false || mergeableState?.lowercased() == "dirty" { self = .conflict; return }
        switch mergeableState?.lowercased() {
        case "blocked", "unstable", "draft", "behind": self = .blocked
        default: self = mergeable == true ? .ready : .unknown
        }
    }
}
