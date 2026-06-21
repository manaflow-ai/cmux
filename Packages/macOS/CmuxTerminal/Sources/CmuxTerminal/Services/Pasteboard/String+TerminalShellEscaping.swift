internal import Foundation

extension String {
    /// The characters terminal paste paths escape with a backslash before
    /// injecting a path or URL as shell input.
    private static let terminalShellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    /// This string escaped for safe injection as terminal shell input.
    ///
    /// Values containing newlines are single-quoted (backslash-escaping a
    /// newline would split the input); everything else gets per-character
    /// backslash escaping of the shell-special set.
    public var terminalShellEscaped: String {
        if contains(where: { $0 == "\n" || $0 == "\r" }) {
            return terminalShellSingleQuoted
        }
        var result = self
        for char in Self.terminalShellEscapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    private var terminalShellSingleQuoted: String {
        let escaped = replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
