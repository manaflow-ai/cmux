public import Foundation

/// Pure filtering rules for Issue Inbox rows.
public struct IssueInboxFilter: Sendable, Equatable {
    /// Status filter. Defaults to open issues.
    public var status: IssueInboxStatusFilter
    /// Optional provider filter.
    public var provider: IssueProviderKind?
    /// Case-insensitive query over title, number, and labels.
    public var query: String

    /// Creates an Issue Inbox filter.
    ///
    /// - Parameters:
    ///   - status: Status filter. Defaults to `.open`.
    ///   - provider: Optional provider filter.
    ///   - query: Case-insensitive query over title, number, and labels.
    public init(
        status: IssueInboxStatusFilter = .open,
        provider: IssueProviderKind? = nil,
        query: String = ""
    ) {
        self.status = status
        self.provider = provider
        self.query = query
    }

    /// Applies the filter to a list of items.
    ///
    /// - Parameter items: Items to filter.
    /// - Returns: Matching items in original order.
    public func apply(to items: [IssueInboxItem]) -> [IssueInboxItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            switch status {
            case .open where item.status != .open:
                return false
            case .closed where item.status != .closed:
                return false
            case .all, .open, .closed:
                break
            }
            if let provider, item.provider != provider {
                return false
            }
            guard !normalizedQuery.isEmpty else {
                return true
            }
            if item.title.lowercased().contains(normalizedQuery) { return true }
            if item.number.lowercased().contains(normalizedQuery) { return true }
            return item.labels.contains { $0.lowercased().contains(normalizedQuery) }
        }
    }
}
