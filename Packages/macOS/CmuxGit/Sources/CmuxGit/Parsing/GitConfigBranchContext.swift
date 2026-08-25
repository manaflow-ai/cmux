import Foundation

/// Selects the branch source used by `includeIf.onbranch` evaluation.
nonisolated enum GitConfigBranchContext: Sendable {
    /// Preserve the legacy direct-file behavior for standalone parser callers.
    case fileBacked

    /// Use a reference snapshot supplied by the owning metadata service.
    /// `nil` means the checkout is detached, unborn, or unreadable and therefore
    /// must not match an `onbranch` condition.
    case resolved(String?)

    func branchName(for repository: ResolvedGitRepository) -> String? {
        switch self {
        case .fileBacked:
            return GitMetadataService.gitBranchName(repository: repository)
        case .resolved(let branchName):
            return branchName
        }
    }
}
