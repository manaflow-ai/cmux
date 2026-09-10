import Foundation

/// Wire mapping for diff review comments, free of AppKit and controller state.
///
/// An instance owns the timestamp formatter, so constructing one per response is
/// what keeps a reply from allocating a formatter per comment. Both surfaces
/// that hand comments to a client use it: the webview bridge (`comments.list`
/// for the diff viewer) and the socket method of the same name.
public struct DiffCommentPayload {
    private let formatter: ISO8601DateFormatter

    /// Creates a mapper. Pass a formatter to share one across several replies or
    /// to pin a specific configuration in tests.
    public init(formatter: ISO8601DateFormatter = ISO8601DateFormatter()) {
        self.formatter = formatter
    }

    /// Serializes one comment, including optional lifecycle state.
    public func json(_ comment: DiffComment) -> [String: Any] {
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
        if let consumedAt = comment.consumedAt {
            json["consumedAt"] = formatter.string(from: consumedAt)
        }
        return json
    }

    /// Builds the `comments.list` reply. Comments delivered to an agent through
    /// a TextBox submission carry `consumedAt` and stay out of the default
    /// listing so callers see only what is still unaddressed.
    public func list(
        comments: [DiffComment],
        repoRoot: String,
        includeConsumed: Bool
    ) -> [String: Any] {
        var listed: [[String: Any]] = []
        listed.reserveCapacity(comments.count)
        for comment in comments where includeConsumed || comment.consumedAt == nil {
            listed.append(json(comment))
        }
        return [
            "repo_root": repoRoot,
            "count": listed.count,
            "comments": listed,
        ]
    }
}
