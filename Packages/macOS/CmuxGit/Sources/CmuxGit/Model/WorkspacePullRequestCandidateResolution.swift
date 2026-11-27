import Foundation

/// The output of resolving candidate seeds: the per-panel candidates plus the
/// repo-keyed indexes the fetch stage needs.
public struct WorkspacePullRequestCandidateResolution: Sendable {
    /// One resolved candidate per seed, in seed order.
    public let candidates: [WorkspacePullRequestCandidate]
    /// All candidate branches grouped by repository slug.
    public let candidateBranchesByRepo: [String: Set<String>]
    /// A representative directory per repository slug (used for diagnostics).
    public let repoDirectoriesBySlug: [String: String]

    /// Creates a candidate resolution.
    public init(
        candidates: [WorkspacePullRequestCandidate],
        candidateBranchesByRepo: [String: Set<String>],
        repoDirectoriesBySlug: [String: String]
    ) {
        self.candidates = candidates
        self.candidateBranchesByRepo = candidateBranchesByRepo
        self.repoDirectoriesBySlug = repoDirectoriesBySlug
    }
}
