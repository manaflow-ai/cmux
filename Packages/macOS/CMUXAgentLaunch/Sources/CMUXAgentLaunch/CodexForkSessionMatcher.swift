import Foundation

/// Selects exactly one Codex fork rollout using parent and process-owned path evidence.
public struct CodexForkSessionMatcher: Sendable {
    /// Creates a stateless fork-session matcher.
    public init() {}

    /// Matches a child rollout without using newest-wins across sibling forks.
    ///
    /// - Parameters:
    ///   - parentSessionID: The session being forked.
    ///   - launchedAt: The fork launch time retained for launch-correlation context.
    ///   - candidates: Rollouts whose metadata names the parent.
    ///   - ownerRolloutPaths: Rollout paths held open by the fork process.
    /// - Returns: The sole process-owned child candidate, or `nil` when evidence is ambiguous.
    public func match(
        parentSessionID: String,
        launchedAt _: Date,
        candidates: [CodexForkSessionCandidate],
        ownerRolloutPaths: Set<String>
    ) -> CodexForkSessionCandidate? {
        guard !parentSessionID.isEmpty, !ownerRolloutPaths.isEmpty else { return nil }
        let matches = candidates
            .filter {
                $0.parentSessionID == parentSessionID
                    && $0.sessionID != parentSessionID
                    && ownerRolloutPaths.contains($0.transcriptPath)
            }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}
