internal import Foundation

/// POSIX shell quoting shared by the script builders. Same pinned behavior
/// as the (module-internal) helpers in `CmuxRemoteSession` and `CmuxCore`.
extension String {
    /// POSIX single-quoting for embedding a value in an `sh -c` script
    /// (`'` becomes `'"'"'`).
    var shellSingleQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
