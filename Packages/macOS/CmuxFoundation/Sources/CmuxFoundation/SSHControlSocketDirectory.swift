internal import Darwin
internal import Foundation

/// Locates the directory for cmux's shared OpenSSH control sockets.
///
/// OpenSSH connects to whatever socket sits at `ControlPath` and hands it the
/// session's terminal without checking who created it, even with
/// `ControlMaster=no`. The directory must therefore be one where no other
/// local user can create an entry, which rules out the shared `/tmp`.
enum SSHControlSocketDirectory {
    /// `%C` expands to a 40-character hex digest.
    static let socketNameLength = 40

    /// macOS caps an AF_UNIX `sun_path` at 104 bytes including the NUL.
    private static let maxUnixSocketPathLength = 103

    /// OpenSSH binds `<ControlPath>.` plus 16 random characters, then renames
    /// that socket into place, so the bound path is 17 bytes longer.
    private static let opensshTransientSuffixLength = 17

    /// Creates `<home>/.cmux/ssh` when missing and returns its resolved path
    /// if only `userID` can add, rename or remove entries in it.
    ///
    /// - Returns: The directory, or `nil` when it is shared, can't be created,
    ///   or can't go into a `ControlPath` verbatim.
    static func prepare(home: String, userID: Int) -> String? {
        guard home.hasPrefix("/") else { return nil }
        let cmuxDirectory = (home as NSString).appendingPathComponent(".cmux")
        let socketDirectory = (cmuxDirectory as NSString).appendingPathComponent("ssh")
        for directory in [cmuxDirectory, socketDirectory] {
            if mkdir(directory, 0o700) != 0, errno != EEXIST { return nil }
        }
        guard let resolvedPointer = realpath(socketDirectory, nil) else { return nil }
        let resolved = String(cString: resolvedPointer)
        free(resolvedPointer)
        guard isUsable(resolved), isPrivate(resolved, userID: userID) else { return nil }
        return resolved
    }

    /// Whether `path` can go into a `ControlPath` and a shell pattern
    /// verbatim, with room for OpenSSH's socket name.
    static func isUsable(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard bytes.count > 1, bytes.first == UInt8(ascii: "/"), bytes.last != UInt8(ascii: "/"),
              bytes.count + 1 + socketNameLength + opensshTransientSuffixLength <= maxUnixSocketPathLength else {
            return false
        }
        // No `%`, `$` or `~`, which OpenSSH expands in a ControlPath, and
        // nothing a shell or an `-o` value would split or interpret.
        return bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"):
                return true
            default:
                return "_@+=:,./-".utf8.contains(byte)
            }
        }
    }

    /// Whether only `userID` can change entries in `directory`, and only
    /// `userID` or root in each directory above it.
    ///
    /// A world-writable ancestor is fine when it is sticky, as `/private/tmp`
    /// is: other users can't move an entry they don't own out of it.
    private static func isPrivate(_ directory: String, userID: Int) -> Bool {
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              Int(info.st_uid) == userID, info.st_mode & 0o022 == 0 else {
            return false
        }
        var ancestor = (directory as NSString).deletingLastPathComponent
        while true {
            guard lstat(ancestor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == 0 || Int(info.st_uid) == userID,
                  info.st_mode & 0o022 == 0 || info.st_mode & mode_t(S_ISVTX) != 0 else {
                return false
            }
            if ancestor == "/" { return true }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
    }
}
