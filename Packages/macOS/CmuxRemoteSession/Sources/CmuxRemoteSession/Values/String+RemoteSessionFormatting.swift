internal import Foundation

// Internal formatting vocabulary the session coordinator and process runner
// share (legacy `WorkspaceRemoteSessionController.shellSingleQuoted` /
// `debugLogSnippet` statics, re-homed onto their natural receiver per the
// foundation-helper ergonomics convention). Quoting output is wire/process
// behavior; do not alter.
extension String {
    /// POSIX single-quoting for embedding a value in an `sh -c` script
    /// (`'` becomes `'"'"'`).
    var shellSingleQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// One-line, length-capped rendering for debug logs: newlines and
    /// carriage returns escaped, trimmed, `""` for empty, `...` past `limit`.
    func debugLogSnippet(limit: Int = 160) -> String {
        let normalized = self
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "\"\"" }
        if normalized.count <= limit {
            return normalized
        }
        return String(normalized.prefix(limit)) + "..."
    }
}
