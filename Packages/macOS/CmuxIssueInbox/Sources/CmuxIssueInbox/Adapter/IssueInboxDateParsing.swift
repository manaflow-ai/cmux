public import Foundation

/// Parses provider ISO-8601 timestamps.
public struct IssueInboxDateParsing: Sendable {
    /// Creates a date parser.
    public init() {}

    /// Parses an ISO-8601 timestamp.
    ///
    /// - Parameter rawValue: Timestamp text from a provider response.
    /// - Returns: Parsed date, or `nil` when parsing fails.
    public func date(from rawValue: String) -> Date? {
        if let date = IssueInboxDateFormatterCache.fractional.date(from: rawValue) {
            return date
        }
        return IssueInboxDateFormatterCache.plain.date(from: rawValue)
    }
}

private enum IssueInboxDateFormatterCache {
    private static let fractionalKey = "CmuxIssueInbox.IssueInboxDateParsing.fractional"
    private static let plainKey = "CmuxIssueInbox.IssueInboxDateParsing.plain"

    static var fractional: ISO8601DateFormatter {
        formatter(
            key: fractionalKey,
            options: [.withInternetDateTime, .withFractionalSeconds]
        )
    }

    static var plain: ISO8601DateFormatter {
        formatter(key: plainKey, options: [.withInternetDateTime])
    }

    private static func formatter(
        key: String,
        options: ISO8601DateFormatter.Options
    ) -> ISO8601DateFormatter {
        let dictionary = Thread.current.threadDictionary
        if let formatter = dictionary[key] as? ISO8601DateFormatter {
            return formatter
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        dictionary[key] = formatter
        return formatter
    }
}
