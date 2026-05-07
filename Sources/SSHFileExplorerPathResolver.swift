import Foundation

/// Pure helpers that compute the remote home directory and the effective
/// file-tree root path for an SSH-bound workspace.
///
/// All members are `nonisolated`: they touch only their `String` arguments
/// and Foundation primitives, so callers may invoke them from any actor or
/// thread, and a future module-level default actor isolation setting will
/// not silently bind them to the main actor.
enum SSHFileExplorerPathResolver {
    /// Derives the conventional remote home directory from the SSH
    /// `<user>@<host>` destination string.
    ///
    /// Linux convention: `$HOME` is `/home/<user>`, except `root` which uses
    /// `/root`. Returns `""` when the destination is `nil`/empty or the user
    /// portion cannot be confidently extracted (e.g. missing `@`, whitespace
    /// only, empty user, empty host). Surrounding whitespace is trimmed;
    /// ports/IPv6 brackets after the host are ignored because we only use
    /// the user portion.
    ///
    /// Examples:
    ///     "imgyu@100.79.206.23"  -> "/home/imgyu"
    ///     "ubuntu@host:2222"      -> "/home/ubuntu"
    ///     "root@host"             -> "/root"
    ///     "user@[::1]:22"         -> "/home/user"
    ///     ""                      -> ""
    ///     "noatsign"              -> ""   (no user portion is reliable)
    ///     "@host"                 -> ""
    ///     "user@"                 -> ""   (no host = malformed)
    nonisolated static func remoteHomePath(from destination: String?) -> String {
        guard let raw = destination?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return ""
        }
        let atParts = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard atParts.count == 2 else { return "" }
        let user = atParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let hostPart = atParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !hostPart.isEmpty else { return "" }
        if user == "root" { return "/root" }
        return "/home/\(user)"
    }

    /// Returns the file-tree root path to use for an SSH-bound workspace.
    ///
    /// `workspaceDirectory` is the workspace's tracked cwd. For SSH workspaces
    /// created on macOS this is typically the Mac caller's cwd
    /// (e.g. `/Users/<x>/Downloads`) and is unreachable on the remote, so we
    /// fall back to the derived remote home when:
    /// - `remoteHomePath` is non-empty (we have a credible anchor), AND
    /// - `workspaceDirectory` looks like a Mac-local path (`/Users/...`,
    ///   `/Volumes/...`).
    ///
    /// In every other case we return the workspace directory unchanged so we
    /// don't accidentally redirect a user who is intentionally rooted at an
    /// already-remote-style path (`/home/...`, `/root`, `/etc`, `/`, etc.).
    nonisolated static func effectiveRootPath(
        workspaceDirectory: String,
        remoteHomePath: String
    ) -> String {
        guard !remoteHomePath.isEmpty else { return workspaceDirectory }
        if isMacLocalPath(workspaceDirectory) {
            return remoteHomePath
        }
        return workspaceDirectory
    }

    /// Returns `true` if `path` is on a macOS-only mount that cannot exist on
    /// a Linux remote: `/Users/...` (home) or `/Volumes/...` (mounted disks).
    ///
    /// `/private/...`, `/tmp/...`, `/etc/...` and other roots that exist on
    /// both platforms are intentionally excluded — those may legitimately be
    /// the user's intended remote target. Matching is case-sensitive: the
    /// canonical macOS spelling is `/Users` / `/Volumes` (capital), and the
    /// remote side is compared exactly even when the local APFS volume is
    /// case-insensitive.
    nonisolated static func isMacLocalPath(_ path: String) -> Bool {
        path.hasPrefix("/Users/") || path.hasPrefix("/Volumes/")
    }
}
