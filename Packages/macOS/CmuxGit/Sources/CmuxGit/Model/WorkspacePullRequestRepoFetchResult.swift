import Foundation

/// The outcome of fetching one repository's pull requests.
public enum WorkspacePullRequestRepoFetchResult: Sendable {
    /// The fetch (or cache read) produced an entry. `usedCache` is `true` when
    /// the entry came from the caller's cache unchanged; `transientBranches`
    /// lists branches whose per-branch lookups failed transiently.
    case success(
        WorkspacePullRequestRepoCacheEntry,
        usedCache: Bool,
        transientBranches: Set<String>
    )
    /// The repository fetch failed transiently (network/auth/rate limit).
    case transientFailure
}
