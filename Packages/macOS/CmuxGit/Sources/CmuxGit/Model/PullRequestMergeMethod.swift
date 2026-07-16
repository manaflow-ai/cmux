import Foundation

/// A merge strategy supported by `gh pr merge`.
public enum PullRequestMergeMethod: String, CaseIterable, Equatable, Hashable, Sendable {
    /// Squash all pull-request commits into one commit.
    case squash
    /// Create a merge commit.
    case merge
    /// Rebase pull-request commits onto the base branch.
    case rebase

    /// The GitHub CLI flag for this merge method.
    public var commandFlag: String { "--\(rawValue)" }

}
