#if DEBUG
public import Foundation

/// DEBUG-only single-line preview formatters for a workspace description/title.
///
/// These are presentation-only transforms with no app state reach: they escape
/// control characters and truncate a string (or an optional string) so a
/// workspace title or description renders on one readable debug log line. They
/// are lifted from `Workspace` as receiver-typed members so call sites read as
/// `text.debugWorkspaceDescriptionPreview(...)` (or the static form for an
/// optional) rather than going through a formatting namespace. `#if DEBUG`-only
/// because the trace lines they feed are themselves debug-only.

public extension String {
    /// DEBUG-only single-line preview of a workspace description/title: escapes
    /// control characters and truncates to `limit` for log readability.
    ///
    /// - Parameters:
    ///   - text: The string to preview, or `nil`.
    ///   - limit: The maximum number of escaped characters to keep before
    ///     truncating. Defaults to `120`.
    /// - Returns: `"nil"` when `text` is `nil`, otherwise the escaped, truncated
    ///   preview.
    static func debugWorkspaceDescriptionPreview(_ text: String?, limit: Int = 120) -> String {
        guard let text else { return "nil" }
        return text.debugWorkspaceDescriptionPreview(limit: limit)
    }

    /// DEBUG-only single-line preview of this string: escapes control characters
    /// and truncates to `limit` for log readability.
    ///
    /// - Parameter limit: The maximum number of escaped characters to keep before
    ///   truncating. Defaults to `120`.
    func debugWorkspaceDescriptionPreview(limit: Int = 120) -> String {
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
