import Foundation

// MARK: - Shared ISO8601 Date Parser

enum ProviderISO8601DateParser {
    /// Formatters are created per call so concurrent parses from different
    /// provider fetch tasks can never share mutable `ISO8601DateFormatter`
    /// state. `ISO8601DateFormatter` is not documented as thread-safe, and
    /// this parser is intentionally lightweight so the extra allocations are
    /// cheaper than the alternatives (locks, thread-local caches).
    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }
        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        return withoutFractional.date(from: string)
    }
}
