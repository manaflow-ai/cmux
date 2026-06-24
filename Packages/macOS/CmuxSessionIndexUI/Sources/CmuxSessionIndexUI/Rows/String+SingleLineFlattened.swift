public import Foundation

extension String {
    /// This string with every line break and tab collapsed to a single space.
    ///
    /// Session titles can carry `<command-message>…\n…` envelopes whose hard line
    /// breaks defeat SwiftUI's `lineLimit(1)`; flattening keeps a row single-line.
    /// CRLF, LF, CR, and tab are each replaced with one space.
    public var singleLineFlattened: String {
        var out = self
        out = out.replacingOccurrences(of: "\r\n", with: " ")
        out = out.replacingOccurrences(of: "\n", with: " ")
        out = out.replacingOccurrences(of: "\r", with: " ")
        out = out.replacingOccurrences(of: "\t", with: " ")
        return out
    }
}
