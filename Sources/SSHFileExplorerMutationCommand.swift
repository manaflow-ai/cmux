import Foundation

/// One remote command the SSH file explorer runs to change the filesystem.
///
/// Every command runs its script under `sh -c`, so it behaves the same whatever
/// the user's login shell is (bash, zsh, fish, csh). The script never contains
/// `'`, `\`, `!` or a newline, which keeps it literal inside single quotes in
/// all of those shells. Paths travel base64-encoded and are decoded by the
/// remote `sh`, so names with quotes, `$`, a leading `-` or non-ASCII (NFC)
/// bytes reach the filesystem unchanged.
///
/// Scripts exit with ``alreadyExistsStatus`` when the target name is taken and
/// ``permissionDeniedStatus`` when the parent directory is not writable.
struct SSHFileExplorerMutationCommand: Equatable, Sendable {
    /// Exit status for "an item with that name already exists" (`EX_CANTCREAT`).
    static let alreadyExistsStatus: Int32 = 73
    /// Exit status for "the parent directory is not writable" (`EX_NOPERM`).
    static let permissionDeniedStatus: Int32 = 77

    /// The command line handed to `ssh`, parsed by the remote login shell.
    let command: String

    private init(script: String) {
        precondition(
            !script.contains("'") && !script.contains("\\") && !script.contains("!") && !script.contains("\n"),
            "SSH mutation scripts must stay literal inside single quotes in every login shell"
        )
        command = "sh -c '\(script)'"
    }

    /// Creates an empty file and never truncates an existing one.
    static func createFile(path: String) -> Self {
        Self(script: [
            decoder,
            assign("t", path),
            assign("dir", parent(of: path)),
            rejectExisting("t"),
            requireWritable("dir"),
            // noclobber makes the redirection itself fail if the file appears
            // between the check above and this line.
            "set -C",
            ": > \"$t\"",
        ].joined(separator: "; "))
    }

    /// Creates a directory; fails if any item already has that name.
    static func createDirectory(path: String) -> Self {
        Self(script: [
            decoder,
            assign("t", path),
            assign("dir", parent(of: path)),
            rejectExisting("t"),
            requireWritable("dir"),
            "mkdir -- \"$t\"",
        ].joined(separator: "; "))
    }

    /// Renames within one directory without replacing an existing item.
    ///
    /// A case-only rename (`Readme.md` to `README.md`) goes through a temporary
    /// name, because on a case-insensitive volume the destination test matches
    /// the source itself.
    /// - Parameter temporaryName: The intermediate name for a case-only rename.
    static func rename(
        path: String,
        to destinationPath: String,
        temporaryName: String = ".cmux-rename-\(UUID().uuidString)"
    ) -> Self {
        let directory = parent(of: path)
        var lines = [
            decoder,
            assign("s", path),
            assign("t", destinationPath),
            assign("dir", directory),
            requireWritable("dir"),
        ]
        if path != destinationPath, path.lowercased() == destinationPath.lowercased() {
            lines += [
                assign("m", (directory as NSString).appendingPathComponent(temporaryName)),
                // The destination may only exist as the source under another case.
                "if \(exists("t")); then [ \"$s\" -ef \"$t\" ] || exit \(alreadyExistsStatus); fi",
                "mv -n -- \"$s\" \"$m\" || exit 1",
                "if \(exists("s")); then exit 1; fi",
                "mv -n -- \"$m\" \"$t\"",
                // Put the item back under its old name if the second step failed.
                "if \(exists("m")); then mv -n -- \"$m\" \"$s\"; exit 1; fi",
            ]
        } else {
            lines += [
                // Without this, a destination directory would receive the source as a child.
                rejectExisting("t"),
                // `mv -n` silently keeps a destination created after the check;
                // the source still being present reports that collision.
                "mv -n -- \"$s\" \"$t\" || exit 1",
                "if \(exists("s")); then exit \(alreadyExistsStatus); fi",
            ]
        }
        return Self(script: lines.joined(separator: "; "))
    }

    /// Permanently removes a file or directory tree.
    static func delete(path: String) -> Self {
        Self(script: [
            decoder,
            assign("t", path),
            assign("dir", parent(of: path)),
            "if \(exists("t")); then :; else exit 74; fi",
            requireWritable("dir"),
            "rm -rf -- \"$t\"",
        ].joined(separator: "; "))
    }

    /// Copies a file or directory tree to a destination that must not exist.
    static func copy(path: String, to destinationPath: String) -> Self {
        Self(script: [
            decoder,
            assign("s", path),
            assign("t", destinationPath),
            assign("dir", parent(of: destinationPath)),
            // `cp -R` into an existing directory would nest the copy inside it.
            rejectExisting("t"),
            requireWritable("dir"),
            "cp -R -p -- \"$s\" \"$t\"",
        ].joined(separator: "; "))
    }

    /// GNU coreutils and macOS accept --decode, BusyBox (Alpine) only -d;
    /// -D is the older macOS short flag.
    private static let decoder = "d() { "
        + ["--decode", "-d", "-D"]
            .map { "printf %s \"$1\" | base64 \($0) 2>/dev/null" }
            .joined(separator: " || ")
        + "; }"

    private static func assign(_ variable: String, _ path: String) -> String {
        let encoded = Data(path.utf8).base64EncodedString()
        return "\(variable)=$(d \(encoded)); [ -n \"$\(variable)\" ] || exit 1"
    }

    private static func exists(_ variable: String) -> String {
        "[ -e \"$\(variable)\" ] || [ -L \"$\(variable)\" ]"
    }

    private static func rejectExisting(_ variable: String) -> String {
        "if \(exists(variable)); then exit \(alreadyExistsStatus); fi"
    }

    private static func requireWritable(_ variable: String) -> String {
        "[ -w \"$\(variable)\" ] || exit \(permissionDeniedStatus)"
    }

    private static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}
