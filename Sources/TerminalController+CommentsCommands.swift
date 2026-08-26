import CmuxDiffComments
import Foundation

/// Socket v2 surface for diff-viewer review comments.
extension TerminalController {
    /// `comments.list` — read-only listing of saved review comments for one git
    /// repository. Callers send the repository path; the store owns
    /// canonicalization and storage, so external tools never depend on its key
    /// scheme or cache semantics. The reply shape lives in `DiffCommentPayload`.
    func v2CommentsList(params: [String: Any]) -> V2CallResult {
        guard let rawRepoRoot = (params["repo_root"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawRepoRoot.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.comments.missingRepoRoot",
                    defaultValue: "A repository path is required."
                ),
                data: nil
            )
        }
        let repoRoot = DiffCommentStore.canonicalRepoRoot(rawRepoRoot)
        return .ok(DiffCommentPayload().list(
            comments: DiffCommentStore.shared.comments(repoRoot: repoRoot),
            repoRoot: repoRoot,
            includeConsumed: (params["include_consumed"] as? Bool) ?? false
        ))
    }
}
