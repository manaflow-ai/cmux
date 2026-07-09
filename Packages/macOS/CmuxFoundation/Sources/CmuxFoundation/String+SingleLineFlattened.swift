import Foundation

/// Collapses every newline and tab in a string to a single space so callers can
/// render multi-line text on one line. Used where a `lineLimit(1)` Text would
/// otherwise honor hard line breaks embedded in the source string (e.g. titles
/// carrying `<command-message>…\n…` envelopes).
extension String {
    /// `self` with `\r\n`, `\n`, `\r`, and `\t` each replaced by a single space.
    public var singleLineFlattened: String {
        var out = self
        out = out.replacingOccurrences(of: "\r\n", with: " ")
        out = out.replacingOccurrences(of: "\n", with: " ")
        out = out.replacingOccurrences(of: "\r", with: " ")
        out = out.replacingOccurrences(of: "\t", with: " ")
        return out
    }
}
