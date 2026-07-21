import Foundation

/// Carries one file mutation reported by an agent transcript.
public struct FileChangePayload: Codable, Hashable, Sendable {
    /// The changed path, when the transcript exposes it.
    public let path: String
    /// The kind of mutation.
    public let changeKind: FileChangeKind
    /// A compact summary of the mutation result, when known.
    public let resultSummary: String?
    /// Runtime correlation identifier, when reported.
    public let toolCallID: String?
    /// Original path for a move or rename.
    public let oldPath: String?
    /// Result path for a move or rename.
    public let newPath: String?
    /// Added-line count, when computable.
    public let additions: Int?
    /// Removed-line count, when computable.
    public let deletions: Int?
    /// Bounded unified diff or patch text for a detail surface.
    public let unifiedDiff: String?

    private enum CodingKeys: String, CodingKey {
        case path
        case changeKind = "change_kind"
        case resultSummary = "result_summary"
        case toolCallID = "tool_call_id"
        case oldPath = "old_path"
        case newPath = "new_path"
        case additions
        case deletions
        case unifiedDiff = "unified_diff"
    }

    /// Creates a file change payload.
    /// - Parameters:
    ///   - path: The changed path, when the transcript exposes it.
    ///   - changeKind: The kind of mutation.
    ///   - resultSummary: A compact summary of the mutation result, when known.
    public init(
        path: String,
        changeKind: FileChangeKind,
        resultSummary: String? = nil,
        toolCallID: String? = nil,
        oldPath: String? = nil,
        newPath: String? = nil,
        additions: Int? = nil,
        deletions: Int? = nil,
        unifiedDiff: String? = nil
    ) {
        self.path = path
        self.changeKind = changeKind
        self.resultSummary = resultSummary
        self.toolCallID = toolCallID
        self.oldPath = oldPath
        self.newPath = newPath
        self.additions = additions
        self.deletions = deletions
        self.unifiedDiff = unifiedDiff
    }
}
