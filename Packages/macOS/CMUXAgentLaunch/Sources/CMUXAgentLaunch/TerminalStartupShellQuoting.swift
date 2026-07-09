import Foundation

/// Quotes individual shell words for the POSIX `sh` startup commands cmux feeds into a restored
/// terminal surface.
///
/// All inputs are quoted so that whatever bytes a user's working directory, command, or argument
/// contains survive verbatim through `$SHELL`. Pure-ASCII values use single-quote escaping
/// (`'\''` for embedded quotes), which `zsh`, `bash`, `fish`, and `csh` all interpret identically;
/// values carrying any non-ASCII byte are emitted as a `printf` octal command substitution so the
/// exact bytes are reproduced without relying on the surface's locale.
///
/// The type is a stateless value; construct one at the call site
/// (`TerminalStartupShellQuoting()`) rather than reaching through a static namespace, per the
/// package design discipline.
public struct TerminalStartupShellQuoting: Sendable, Equatable {
    /// Creates a shell-word quoter. The type holds no state.
    public init() {}

    /// Single-quotes `value` as one POSIX `sh` word.
    ///
    /// Pure-ASCII input is wrapped in single quotes with embedded quotes escaped as `'\''`; input
    /// with any byte `>= 0x80` is emitted as a `printf` octal command substitution so the exact
    /// bytes round-trip regardless of the surface's locale.
    public func singleQuoted(_ value: String) -> String {
        if value.utf8.contains(where: { $0 >= 0x80 }) {
            return asciiPrintfCommandSubstitution(for: value)
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Renders `value` as one shell token, leaving it bare when it is safe to.
    ///
    /// When `allowingBareASCII` is `true` and `value` contains only the unreserved set
    /// `[A-Za-z0-9_./:=+-]`, it is returned unquoted; otherwise it falls back to
    /// ``singleQuoted(_:)`` (including the non-ASCII `printf` path).
    public func shellToken(_ value: String, allowingBareASCII: Bool) -> String {
        if value.utf8.contains(where: { $0 >= 0x80 }) {
            return asciiPrintfCommandSubstitution(for: value)
        }
        if allowingBareASCII,
           value.range(of: "[^A-Za-z0-9_./:=+-]", options: .regularExpression) == nil {
            return value
        }
        return singleQuoted(value)
    }

    private func asciiPrintfCommandSubstitution(for value: String) -> String {
        let octalBytes = value.utf8
            .map { String(format: #"\%03o"#, Int($0)) }
            .joined()
        return #""$(printf '"# + octalBytes + #"')""#
    }
}
