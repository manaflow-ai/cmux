import Foundation

/// Query parameters for listing local inbox items.
public struct InboxListQuery: Codable, Equatable, Sendable {
    /// Row filter to apply.
    public var filter: InboxListFilter
    /// Optional source filter.
    public var source: InboxSource?
    /// Maximum number of rows.
    public var limit: Int
    /// Whether archived threads should be included.
    public var includeArchived: Bool

    /// Creates a list query.
    /// - Parameters:
    ///   - filter: Row filter to apply.
    ///   - source: Optional source filter.
    ///   - limit: Maximum number of rows.
    ///   - includeArchived: Whether archived threads should be included.
    public init(
        filter: InboxListFilter = .all,
        source: InboxSource? = nil,
        limit: Int = 50,
        includeArchived: Bool = false
    ) {
        self.filter = filter
        self.source = source
        self.limit = max(1, min(limit, 500))
        self.includeArchived = includeArchived
    }
}
