import Foundation

/// The POSIX `cd` that starts a remote session in the caller's `--cwd`.
///
/// A value rather than a namespace function: the remote bootstrap builder and
/// the CLI's raw remote-command path both need the same quoting, and both hold
/// one of these for the directory they are launching into.
struct RemoteWorkingDirectoryScript {
    /// The requested remote directory, or nil when the session keeps the login
    /// shell's default directory.
    private let path: String?

    /// Creates a script for `path`; blank and nil paths produce no lines.
    init(path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Shell lines that change directory, quoted so the path is never
    /// interpreted as shell syntax.
    ///
    /// A leading `~` expands against the remote `$HOME` because the local shell
    /// never saw the value to expand it. A failed `cd` warns and keeps the
    /// session in the default directory rather than dropping the connection.
    var lines: [String] {
        guard let path else { return [] }
        return [
            "if ! cd -- \(quotedTarget(for: path)) 2>/dev/null; then",
            "  printf 'cmux: --cwd: cannot change to %s\\n' \(Self.shellQuote(path)) >&2",
            "fi",
        ]
    }

    private func quotedTarget(for path: String) -> String {
        if path == "~" {
            return "\"$HOME\""
        }
        if path.hasPrefix("~/") {
            return "\"$HOME\"/" + Self.shellQuote(String(path.dropFirst(2)))
        }
        return Self.shellQuote(path)
    }

    private static func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
