import Foundation

public extension String {
    /// This string single-quoted for safe POSIX shell injection, with non-ASCII
    /// values rendered through a `printf` octal command substitution.
    ///
    /// ASCII-only values are wrapped in single quotes with embedded single
    /// quotes escaped via the standard `'\''` splice. Any value containing a
    /// byte `>= 0x80` is encoded as `"$(printf '\NNN…')"`, so the bytes survive
    /// shells and locales that would otherwise mangle the literal. The escaping
    /// is byte-faithful: the quote and octal sequences are emitted exactly.
    var posixShellQuoted: String {
        if utf8.contains(where: { $0 >= 0x80 }) {
            return Self.asciiPrintfCommandSubstitution(for: self)
        }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// This string as a single shell token, optionally left bare when it is
    /// already shell-safe ASCII.
    ///
    /// Non-ASCII values go through the `printf` octal command substitution. When
    /// `allowingBareASCII` is true and the value contains only the safe set
    /// `[A-Za-z0-9_./:=+-]`, it is returned unquoted; otherwise it falls back to
    /// `posixShellQuoted`.
    func posixShellToken(allowingBareASCII: Bool) -> String {
        if utf8.contains(where: { $0 >= 0x80 }) {
            return Self.asciiPrintfCommandSubstitution(for: self)
        }
        if allowingBareASCII,
           range(of: "[^A-Za-z0-9_./:=+-]", options: .regularExpression) == nil {
            return self
        }
        return posixShellQuoted
    }

    private static func asciiPrintfCommandSubstitution(for value: String) -> String {
        let octalBytes = value.utf8
            .map { String(format: #"\%03o"#, Int($0)) }
            .joined()
        return #""$(printf '"# + octalBytes + #"')""#
    }
}
