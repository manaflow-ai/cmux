import Foundation

/// Wire mapping for diff review comments, kept free of AppKit and controller
/// state so it can be unit tested directly — and lifted behind a package
/// boundary later without touching its callers.
///
/// Both surfaces that hand comments to a client go through here: the webview
/// bridge (`comments.list` for the diff viewer) and the socket method of the
/// same name.
enum DiffCommentPayload {
    /// Serializes one comment. Callers mapping several comments pass a shared
    /// `formatter` so a reply does not allocate one per comment.
    static func json(_ comment: DiffComment, formatter: ISO8601DateFormatter) -> [String: Any] {
        var json: [String: Any] = [
            "id": comment.id.uuidString,
            "filePath": comment.filePath,
            "side": comment.side,
            "startLine": comment.startLine,
            "endLine": comment.endLine,
            "lineText": comment.lineText,
            "message": comment.message,
            "submissionText": comment.submissionText ?? "",
            "createdAt": formatter.string(from: comment.createdAt),
            "updatedAt": formatter.string(from: comment.updatedAt)
        ]
        if let endSide = comment.endSide {
            json["endSide"] = endSide
        }
        return json
    }

    /// Serializes one comment with its own formatter, for single-comment replies.
    static func json(_ comment: DiffComment) -> [String: Any] {
        json(comment, formatter: ISO8601DateFormatter())
    }

    /// Builds the `comments.list` reply. Comments delivered to an agent through
    /// a TextBox submission carry `consumedAt` and stay out of the default
    /// listing so callers see only what is still unaddressed.
    static func list(
        comments: [DiffComment],
        repoRoot: String,
        includeConsumed: Bool
    ) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var listed: [[String: Any]] = []
        listed.reserveCapacity(comments.count)
        for comment in comments where includeConsumed || comment.consumedAt == nil {
            var entry = json(comment, formatter: formatter)
            if let consumedAt = comment.consumedAt {
                entry["consumedAt"] = formatter.string(from: consumedAt)
            }
            listed.append(entry)
        }
        return [
            "repo_root": repoRoot,
            "count": listed.count,
            "comments": listed,
        ]
    }
}
