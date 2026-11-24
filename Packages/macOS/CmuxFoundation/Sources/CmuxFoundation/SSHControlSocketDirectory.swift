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
    ///
    /// - Parameter namespace: The cmux build these sockets belong to, from ``appNamespace()``.
    ///   `nil` is the release app, which keeps `<home>/.cmux/ssh` itself; any other build gets
    ///   a subdirectory of its own.
    static func prepare(home: String, userID: Int, namespace: String? = nil) -> String? {
        guard home.hasPrefix("/") else { return nil }
        let cmuxDirectory = (home as NSString).appendingPathComponent(".cmux")
        let sharedDirectory = (cmuxDirectory as NSString).appendingPathComponent("ssh")
        var directories = [cmuxDirectory, sharedDirectory]
        if let namespace {
            directories.append((sharedDirectory as NSString).appendingPathComponent(directoryName(for: namespace)))
        }
        let socketDirectory = directories[directories.count - 1]
        for directory in directories {
            if mkdir(directory, 0o700) != 0, errno != EEXIST { return nil }
        }
        guard let resolvedPointer = realpath(socketDirectory, nil) else { return nil }
        let resolved = String(cString: resolvedPointer)
        free(resolvedPointer)
        guard isUsable(resolved), isPrivate(resolved, userID: userID) else { return nil }
        return resolved
    }

    /// The release app's bundle identifier. Its sockets stay where they have always been.
    static let releaseBundleIdentifier = "com.cmuxterm.app"

    /// Which cmux build this process belongs to, or `nil` for the release app.
    ///
    /// The release app, a nightly and tagged development builds can run side by side, and each
    /// opens `cmux ssh` connections to the same hosts. With one directory, `%C` gave them the same
    /// master. On a host that allows one session per connection (`MaxSessions 1`), whichever build
    /// opened it holds its only session, and the other builds' connections are refused
    /// ("Session open refused by peer"). Measured: a second build's `cmux ssh` failed outright
    /// while the first build's workspace was open.
    ///
    /// The app knows its bundle. The bundled CLI does not, since `Bundle.main` has no identifier
    /// for a command-line tool, so it reads the identifier of the app its executable sits in. The
    /// two then agree on the directory.
    static func appNamespace(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        executableURL: URL? = Bundle.main.executableURL
    ) -> String? {
        let identifier = bundleIdentifier ?? executableURL.flatMap(enclosingAppBundleIdentifier)
        guard let identifier, !identifier.isEmpty, identifier != releaseBundleIdentifier else { return nil }
        return identifier
    }

    /// The bundle identifier of the `.app` that contains `executableURL`, following symlinks so a
    /// linked `cmux` on PATH resolves to the app it came from.
    static func enclosingAppBundleIdentifier(_ executableURL: URL) -> String? {
        var url = executableURL.resolvingSymlinksInPath()
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                return Bundle(url: url)?.bundleIdentifier
            }
        }
        return nil
    }

    /// A short, fixed-length directory name for a namespace, so a long tag cannot push the socket
    /// path past the AF_UNIX limit. Eight hex characters: the nested directory costs nine bytes of
    /// a 103-byte path that already holds a 40-character socket name and OpenSSH's 17-byte bind
    /// suffix. A home too long to fit the extra bytes shares no connections, as one too long for
    /// the shared directory already does.
    static func directoryName(for namespace: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in namespace.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%08llx", hash & 0xffff_ffff)
    }

    /// Whether `name` is a directory name ``directoryName(for:)`` produces.
    static func isNamespaceDirectoryName(_ name: String) -> Bool {
        name.utf8.count == 8 && name.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
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
