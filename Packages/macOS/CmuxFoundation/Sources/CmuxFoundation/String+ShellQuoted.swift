import Foundation

public extension String {
    /// This string single-quoted for safe shell injection, left bare when it is
    /// already shell-safe ASCII.
    ///
    /// Equivalent to ``posixShellToken(allowingBareASCII:)`` with
    /// `allowingBareASCII` true: values containing only the safe set
    /// `[A-Za-z0-9_./:=+-]` are returned unquoted, non-ASCII goes through the
    /// `printf` octal command substitution, and everything else is single-quoted
    /// with embedded single quotes escaped via the standard `'\''` splice.
    ///
    /// ```swift
    /// "a b".shellQuoted              // -> "'a b'"
    /// "env GROK_HOME=\(home.shellQuoted) \(command)"
    /// ```
    var shellQuoted: String {
        posixShellToken(allowingBareASCII: true)
    }
}
