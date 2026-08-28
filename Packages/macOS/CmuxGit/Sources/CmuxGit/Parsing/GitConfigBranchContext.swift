import Dispatch
import Foundation

/// Selects the branch source used by `includeIf.onbranch` evaluation.
nonisolated enum GitConfigBranchContext: Sendable {
    /// Preserve the legacy direct-file behavior for standalone parser callers.
    case fileBacked

    /// Use a reference snapshot supplied by the owning metadata service.
    /// `nil` means the checkout is detached, unborn, or unreadable and therefore
    /// must not match an `onbranch` condition.
    case resolved(String?)

    func branchName(
        for repository: ResolvedGitRepository,
        deadline: DispatchTime? = nil
    ) -> String? {
        switch self {
        case .fileBacked:
            let effectiveDeadline = deadline
                ?? (DispatchTime.now() + GitMetadataSafetyConfiguration().gitStatusWallTime)
            let headURL = URL(fileURLWithPath: repository.gitDirectory)
                .appendingPathComponent("HEAD")
            guard case let .contents(contents, _) = GitConfigFileReader().read(
                at: headURL,
                maximumByteCount: 16 * 1_024,
                deadline: effectiveDeadline
            ) else {
                return nil
            }
            let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "ref: refs/heads/"
            guard trimmed.hasPrefix(prefix) else { return nil }
            return GitMetadataService.normalizedBranchName(String(trimmed.dropFirst(prefix.count)))
        case .resolved(let branchName):
            return branchName
        }
    }
}
