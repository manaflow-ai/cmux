import Foundation

/// The output of resolving candidate seeds: the per-panel candidates plus the
/// reference-keyed indexes the fetch stage needs.
public struct WorkspacePullRequestCandidateResolution: Sendable {
    /// One resolved candidate per seed, in seed order.
    public let candidates: [WorkspacePullRequestCandidate]
    /// All candidate branches grouped by repository reference.
    public let candidateBranchesByRepo: [GitHubRepositoryReference: Set<String>]
    /// A representative directory per repository reference.
    public let repoDirectoriesByReference: [GitHubRepositoryReference: String]

    /// Creates a candidate resolution.
    ///
    /// - Parameters:
    ///   - candidates: Resolved panel candidates in seed order.
    ///   - candidateBranchesByRepo: Branch names grouped by repository.
    ///   - repoDirectoriesByReference: Representative directory per repository.
    public init(
        candidates: [WorkspacePullRequestCandidate],
        candidateBranchesByRepo: [GitHubRepositoryReference: Set<String>],
        repoDirectoriesByReference: [GitHubRepositoryReference: String]
    ) {
        self.candidates = candidates
        self.candidateBranchesByRepo = candidateBranchesByRepo
        self.repoDirectoriesByReference = repoDirectoriesByReference
    }
}
