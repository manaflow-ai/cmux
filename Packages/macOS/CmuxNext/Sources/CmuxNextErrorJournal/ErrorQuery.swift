public import Foundation

/// Which entries ``ErrorJournal/entries(_:)`` returns and in what order.
public struct ErrorQuery: Sendable, Equatable {
    /// The order of the answer.
    public enum Order: String, Sendable {
        /// Newest occurrence first.
        case recent
        /// Most occurrences first.
        case count
    }

    /// Only entries seen at or after this date.
    public var since: Date?
    /// Only entries whose source equals one of these or starts with `<one>:`; empty means all.
    public var sources: [String]
    /// Only entries at least this bad.
    public var minimumLevel: ErrorLevel
    /// Only entries whose template or sample contains this text, ignoring case.
    public var text: String?
    /// The order.
    public var order: Order
    /// Most entries returned.
    public var limit: Int

    /// Makes a query; the defaults return the 50 newest entries of every source and level.
    public init(since: Date? = nil, sources: [String] = [], minimumLevel: ErrorLevel = .warning,
                text: String? = nil, order: Order = .recent, limit: Int = 50) {
        self.since = since
        self.sources = sources
        self.minimumLevel = minimumLevel
        self.text = text
        self.order = order
        self.limit = limit
    }

    func matches(_ entry: ErrorEntry) -> Bool {
        // `since` comes from the control socket (`since_ms`, `since`): compared as a Double, a date
        // past Int64 milliseconds matches nothing, one before it everything, and NaN no filter.
        if let since, Double(entry.lastMs) < (since.timeIntervalSince1970 * 1000).rounded(.towardZero) { return false }
        if entry.level < minimumLevel { return false }
        if !sources.isEmpty, !sources.contains(where: { entry.source == $0 || entry.source.hasPrefix($0 + ":") }) {
            return false
        }
        if let text, !text.isEmpty,
           entry.template.range(of: text, options: .caseInsensitive) == nil,
           entry.sample.range(of: text, options: .caseInsensitive) == nil {
            return false
        }
        return true
    }
}
