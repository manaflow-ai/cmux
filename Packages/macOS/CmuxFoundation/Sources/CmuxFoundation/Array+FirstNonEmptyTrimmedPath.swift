import Foundation

/// Helpers for selecting the first usable path string from an ordered list of
/// optional candidates, so callers can collapse a fallback chain of possibly
/// empty or whitespace-only paths into a single optional at the use site.
extension Array where Element == String? {
    /// The first candidate that is non-`nil` and non-empty after trimming
    /// leading and trailing whitespace and newlines, returned already trimmed.
    ///
    /// Returns `nil` when every candidate is `nil`, empty, or whitespace-only.
    public var firstNonEmptyTrimmedPath: String? {
        for candidate in self {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}
