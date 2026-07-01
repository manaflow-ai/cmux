/// A file modification by the agent; renders as a diff card.
public struct ChatFileEdit: Sendable, Equatable, Codable {
    /// The nature of the modification.
    public enum Operation: String, Sendable, Equatable, Codable {
        /// An in-place edit of an existing file.
        case edit
        /// A whole-file write (create or overwrite).
        case write
        /// A file deletion.
        case delete
    }

    /// Path of the modified file, as the agent reported it.
    public let filePath: String

    /// The nature of the modification.
    public let operation: Operation

    /// Count of added lines, when computable.
    public let additions: Int?

    /// Count of removed lines, when computable.
    public let deletions: Int?

    /// A unified-diff rendering of the change, possibly truncated at the
    /// producing side. `nil` when the producer could not construct one.
    public let unifiedDiff: String?

    /// Creates a file edit record.
    ///
    /// - Parameters:
    ///   - filePath: Path of the modified file.
    ///   - operation: The nature of the modification.
    ///   - additions: Added-line count when computable.
    ///   - deletions: Removed-line count when computable.
    ///   - unifiedDiff: Unified-diff text, possibly truncated.
    public init(
        filePath: String,
        operation: Operation,
        additions: Int? = nil,
        deletions: Int? = nil,
        unifiedDiff: String? = nil
    ) {
        self.filePath = filePath
        self.operation = operation
        self.additions = additions
        self.deletions = deletions
        self.unifiedDiff = unifiedDiff
    }

    private enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case operation
        case additions
        case deletions
        case unifiedDiff = "unified_diff"
    }
}
