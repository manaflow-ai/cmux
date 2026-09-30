import Foundation

/// POSIX shell quoting for commands sent over `exec`.
extension String {
    /// The string wrapped in POSIX single quotes, with embedded single quotes
    /// escaped via the standard `'\''` splice.
    public var posixShellSingleQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// This path quoted for a remote shell, expanding a leading `~` through
    /// `$HOME` on the remote.
    var remoteShellPath: String {
        if self == "~" { return "\"$HOME\"" }
        if hasPrefix("~/") { return "\"$HOME\"/" + String(dropFirst(2)).posixShellSingleQuoted }
        return posixShellSingleQuoted
    }

    /// A command that runs this script under `/bin/sh` regardless of the
    /// user's login shell.
    var bourneShellCommand: String {
        "/bin/sh -c " + posixShellSingleQuoted
    }
}
