public import Foundation

/// Refresh outcome for one source.
public struct IssueInboxRefreshSourceResult: Codable, Equatable, Sendable {
    /// Number of items fetched for a successful source.
    public var count: Int?
    /// Error text for a failed source.
    public var error: String?

    /// Creates a per-source refresh result.
    ///
    /// - Parameters:
    ///   - count: Number of fetched items.
    ///   - error: Error text for a failed source.
    public init(count: Int? = nil, error: String? = nil) {
        self.count = count
        self.error = error
    }
}
