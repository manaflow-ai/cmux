#if DEBUG
import Foundation

public extension String {
    /// A single-line, length-bounded preview of this string for debug logging.
    ///
    /// Backslashes, newlines, carriage returns, and tabs are escaped to their
    /// two-character forms so the preview stays on one log line. When the escaped
    /// result exceeds `limit` characters, it is truncated to `limit` and suffixed
    /// with `"..."`. Optionality lives at the call site: pair with `?? "nil"` to
    /// preview an optional string.
    ///
    /// ```swift
    /// maybeTitle?.debugDescriptionPreview(limit: 80) ?? "nil"
    /// ```
    ///
    /// - Parameter limit: The maximum number of escaped characters to keep before truncating.
    /// - Returns: The escaped, length-bounded preview.
    func debugDescriptionPreview(limit: Int = 120) -> String {
        let escaped = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        if escaped.count <= limit {
            return escaped
        }
        return "\(escaped.prefix(limit))..."
    }
}
#endif
