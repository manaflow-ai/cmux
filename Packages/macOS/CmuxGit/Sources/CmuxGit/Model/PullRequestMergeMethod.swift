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

    /// Returns allowed methods with the repository default first, falling back to squash.
    /// - Parameters:
    ///   - settings: The repository's allowed merge methods.
    ///   - defaultMethod: The preferred repository method, when known.
    /// - Returns: Allowed methods in picker order.
    static func orderedAllowed(
        settings: GitHubRepositoryMergeSettings,
        defaultMethod: PullRequestMergeMethod?
    ) -> [PullRequestMergeMethod] {
        let allowed = allCases.filter { method in
            switch method {
            case .squash: settings.squashMergeAllowed
            case .merge: settings.mergeCommitAllowed
            case .rebase: settings.rebaseMergeAllowed
            }
        }
        guard !allowed.isEmpty else { return [.squash] }

        let first = defaultMethod.flatMap { allowed.contains($0) ? $0 : nil }
            ?? (allowed.contains(.squash) ? .squash : allowed[0])
        return [first] + allowed.filter { $0 != first }
    }
}
