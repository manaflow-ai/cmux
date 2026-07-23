public import Foundation

/// One ordinary Markdown note discovered in a session's `notes` directory.
public struct CmuxProjectNote: Identifiable, Equatable, Sendable {
    /// Stable-for-the-current-scan identity equal to ``relativePath``.
    public let id: String
    /// Note filename including its extension.
    public let name: String
    /// Current path relative to the project's `.cmux` filesystem.
    public let relativePath: String
    /// Current absolute local path.
    public let absolutePath: String
    /// Prompt-ready project-relative reference.
    public let reference: String
    /// Current byte size, when available.
    public let size: Int64?
    /// Current filesystem modification date, when available.
    public let modifiedAt: Date?

    /// Creates a live filesystem note value.
    ///
    /// - Parameters:
    ///   - name: Note filename including its extension.
    ///   - relativePath: Current `.cmux`-relative path.
    ///   - absolutePath: Current absolute local path.
    ///   - size: Current byte size, when available.
    ///   - modifiedAt: Current filesystem modification date, when available.
    public init(
        name: String,
        relativePath: String,
        absolutePath: String,
        size: Int64?,
        modifiedAt: Date?
    ) {
        self.id = relativePath
        self.name = name
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.reference = ".cmux/\(relativePath)"
        self.size = size
        self.modifiedAt = modifiedAt
    }
}
