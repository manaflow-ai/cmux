import Foundation

/// Socket v2 surface for diff-viewer review comments.
extension TerminalController {
    /// `comments.list` — read-only listing of saved review comments for one git
    /// repository. Callers send the repository path; the store owns
    /// canonicalization and storage, so external tools never depend on its key
    /// scheme or cache semantics.
    func v2CommentsList(params: [String: Any]) -> V2CallResult {
        guard let rawRepoRoot = (params["repo_root"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawRepoRoot.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.comments.missingRepoRoot",
                    defaultValue: "comments.list requires a repo_root string"
                ),
                data: nil
            )
        }
        let repoRoot = DiffCommentStore.canonicalRepoRoot(rawRepoRoot)
        return .ok(Self.commentsListPayload(
            comments: DiffCommentStore.shared.comments(repoRoot: repoRoot),
            repoRoot: repoRoot,
            includeConsumed: (params["include_consumed"] as? Bool) ?? false
        ))
    }

    /// Builds the `comments.list` reply. Comments delivered to an agent through
    /// a TextBox submission carry `consumedAt` and stay out of the default
    /// listing so callers see only what is still unaddressed.
    nonisolated static func commentsListPayload(
        comments: [DiffComment],
        repoRoot: String,
        includeConsumed: Bool
    ) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var listed: [[String: Any]] = []
        listed.reserveCapacity(comments.count)
        for comment in comments where includeConsumed || comment.consumedAt == nil {
            var json = DiffCommentsBridge.commentJSON(comment, formatter: formatter)
            if let consumedAt = comment.consumedAt {
                json["consumedAt"] = formatter.string(from: consumedAt)
            }
            listed.append(json)
        }
        return [
            "repo_root": repoRoot,
            "count": listed.count,
            "comments": listed,
        ]
    }
}
