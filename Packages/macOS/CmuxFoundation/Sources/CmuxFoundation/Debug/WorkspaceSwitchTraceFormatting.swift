#if DEBUG
public import Foundation

/// Pure value-to-string formatters used by the workspace-switch debug trace log.
///
/// These are presentation-only transforms with no app state reach: they render a
/// workspace identifier, a list of identifiers, a millisecond duration, or a title
/// preview into the compact tokens that the `ws.*` debug trace lines emit. They are
/// lifted from `TabManager` as receiver-typed extensions so call sites read as
/// `id.debugShortWorkspaceId` rather than going through a static formatting namespace.
/// `#if DEBUG`-only because the trace log they feed is itself debug-only.

public extension UUID {
    /// The first five characters of this UUID's string.
    ///
    /// Used to render a single workspace identifier in a `ws.*` debug trace line
    /// without flooding it with full UUIDs.
    var debugShortWorkspaceId: String {
        String(uuidString.prefix(5))
    }
}

public extension Optional where Wrapped == UUID {
    /// The first five characters of the wrapped UUID's string, or `"nil"` when absent.
    ///
    /// Mirrors ``UUID/debugShortWorkspaceId`` so call sites can render either a
    /// `UUID` or a `UUID?` workspace identifier identically in a `ws.*` debug
    /// trace line.
    var debugShortWorkspaceId: String {
        self?.debugShortWorkspaceId ?? "nil"
    }
}

public extension Collection where Element == UUID {
    /// A bracketed, comma-joined list of the five-character prefixes of these UUIDs.
    ///
    /// Renders as `"[]"` when empty, otherwise `"[abcde,fghij]"`. Used to render a
    /// set of workspace identifiers (mounted, added, removed) in a `ws.*` debug
    /// trace line.
    var debugShortWorkspaceIds: String {
        if isEmpty { return "[]" }
        return "[" + map { String($0.uuidString.prefix(5)) }.joined(separator: ",") + "]"
    }
}

public extension Double {
    /// This value formatted as a millisecond duration, e.g. `"12.34ms"`.
    ///
    /// Used to render elapsed times in `ws.*` debug trace lines.
    var debugMillisecondsText: String {
        String(format: "%.2fms", self)
    }
}

public extension String {
    /// A single-line, length-bounded preview of this string for a debug trace line.
    ///
    /// Escapes backslashes, newlines, carriage returns, tabs, and double quotes so
    /// the value stays on one trace line, then truncates to `limit` characters with
    /// a trailing `"..."` when it would otherwise be longer.
    ///
    /// - Parameter limit: The maximum number of characters of the escaped string to
    ///   keep before truncating. Defaults to `120`.
    func debugTracePreview(limit: Int = 120) -> String {
        let escaped = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard escaped.count > limit else { return escaped }
        return "\(escaped.prefix(limit))..."
    }
}
#endif
