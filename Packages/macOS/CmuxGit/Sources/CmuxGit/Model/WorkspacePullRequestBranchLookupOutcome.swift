import Foundation

/// The cache entry produced by a batch of per-branch lookups, plus the branches
/// that failed transiently.
struct WorkspacePullRequestBranchLookupOutcome: Sendable {
    let cacheEntry: WorkspacePullRequestRepoCacheEntry
    let transientBranches: Set<String>
}
