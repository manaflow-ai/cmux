import Darwin
import Foundation

/// Executes the REPL's `fs` operations inside a `BrowserReplFileSandbox`.
///
/// Every operation takes and returns JSON-compatible values so the
/// JavaScriptCore bridge can pass them as strings. Errors carry Node error
/// codes so the runtime can build Node-compatible `Error` objects.
///
/// Like Node, `rm`, `rename` and `lstat` act on a symbolic link itself and
/// the other operations act on what it points to. `rename` and `copyFile`
/// replace an existing destination atomically: it stays intact until the new
/// file is complete.
///
/// The path check and the system call are one: every operation walks from
/// its root's directory, held open since the fs first opened it (a rename of
/// the root's path, or a link put in its place, changes nothing), one entry
/// at a time, with `openat` and
/// `O_NOFOLLOW`, and acts on the entry relative to the directory it holds
/// open (`openat`, `fstatat`, `mkdirat`, `unlinkat`, `renameat`). A link on
/// the way is read with `readlinkat` and followed only while it stays inside
/// a root, so neither another session nor another local process can swap a
/// link in for a directory between the check and the use: the directory
/// already open is the one acted on.
///
/// A directory held open stays usable after it is moved, and a session
/// whose root holds another session's root can move a directory below the
/// inner root out of it while an operation of the inner session holds it.
/// So every system call that acts relative to a directory below a root
/// (`openat` of the file or directory acted on, `fstatat`, `mkdirat`,
/// `unlinkat`, `renameat`) runs under ``BrowserReplFileSandbox/pathChangeLock``,
/// which every REPL `fs.rename` holds, right after a walk up the
/// directory's `..` entries reaches the root (by identity): a directory
/// moved out fails the call with `EACCES` and nothing is made, written or
/// removed there. A file already open stays the file that was opened
/// inside the root.
///
/// Files are opened with `O_NONBLOCK` and checked with `fstat` before any
/// read or write: a FIFO, socket or device fails with `EINVAL` at once
/// instead of waiting for its other end, and `readFile` refuses a file over
/// `maxReadFileBytes`. One `writeFile` (also an append) or `copyFile` writes
/// at most ``BrowserReplWriteBudget/maximumBytesPerCall`` and a session at
/// most ``BrowserReplWriteBudget/maximumBytesPerSession`` in all, each
/// refused before anything is written, and they write in chunks that stop
/// when the session cancels the call (its cell timed out or the session
/// closed). No lock is held across operations: the descriptor walk is what
/// keeps two sessions on one root, or a session and another process, from
/// racing each other's checks, and ``BrowserReplFileSandbox/pathChangeLock``
/// is held only for one system call and its directory's check, so a slow
/// operation holds only its own session's thread.
public struct BrowserReplFileSystem: Sendable {
    /// The largest file `readFile` reads, 64 MiB (the fetch body limit).
    public static let maxReadFileBytes = 64 << 20

    /// The most entries `readdir` lists: its whole list goes to the
    /// session's JavaScript thread, so a larger directory is refused
    /// (`ERR_FS_DIR_TOO_LARGE`) once the read passes this many.
    public static let maxDirectoryEntries = 10_000

    /// The sandbox that authorizes every path.
    public var sandbox: BrowserReplFileSandbox

    /// The session's own canonical temporary directory, a second root next
    /// to the sandbox root, or `nil` for none.
    public let temporaryRoot: String?

    /// Each root's directory, held open from when the fs first opened it.
    let rootDirectories: BrowserReplRootDirectories

    /// What the session may still write, shared by its fs copies.
    let writeBudget: BrowserReplWriteBudget

    /// Whether the session cancelled the running call; long writes and
    /// copies check it between chunks.
    let isCancelled: @Sendable () -> Bool

    /// - Parameter temporaryDirectory: The session's private temporary
    ///   directory (`os.tmpdir()` in the REPL), never a directory other
    ///   sessions or apps share; `nil` gives the sandbox root only.
    public init(sandbox: BrowserReplFileSandbox, temporaryDirectory: String? = nil) {
        self.init(
            sandbox: sandbox,
            temporaryDirectory: temporaryDirectory,
            rootDescriptor: nil,
            temporaryDescriptor: nil,
            writeBudget: BrowserReplWriteBudget(),
            isCancelled: { false }
        )
    }

    /// Opens each root that exists now and holds it open; a root that does
    /// not exist yet is held from when an operation first opens or creates
    /// it. `rootDescriptor` and `temporaryDescriptor` are the roots'
    /// directories the caller already holds open (the session created them).
    /// `writeBudget` is what the session may still write (shared when the
    /// session moves to another root), and `isCancelled` tells a long write
    /// or copy to stop.
    init(
        sandbox: BrowserReplFileSandbox,
        temporaryDirectory: String?,
        rootDescriptor: BrowserReplDescriptor?,
        temporaryDescriptor: BrowserReplDescriptor?,
        writeBudget: BrowserReplWriteBudget,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        self.sandbox = sandbox
        self.writeBudget = writeBudget
        self.isCancelled = isCancelled
        let temporaryRoot = temporaryDirectory.map {
            BrowserReplFileSandbox.canonicalize(BrowserReplFileSandbox.lexicallyNormalized($0))
        }
        self.temporaryRoot = temporaryRoot
        rootDirectories = BrowserReplRootDirectories(
            [(sandbox.root, rootDescriptor)] + (temporaryRoot.map { [($0, temporaryDescriptor)] } ?? [])
        )
    }

    /// Runs one operation. See `docs/browser-repl/driver-protocol.md` for ops.
    public func perform(_ operation: String, arguments: [String: Any]) -> Result<Any, BrowserReplFileSystemError> {
        perform(operation, arguments: arguments, copyContents: nil)
    }

    /// Runs one operation like ``perform(_:arguments:)``.
    ///
    /// - Parameter copyContents: What `copyFile` writes in place of the
    ///   source's bytes (the session masks its secrets there), or `nil` to
    ///   copy them as they are. With it, the copy reads the whole source
    ///   first, so a source over ``maxReadFileBytes`` is refused
    ///   (`ERR_FS_FILE_TOO_LARGE`); an error it throws fails the copy and
    ///   leaves no file.
    /// - Parameter opened: Told the identity of the file `readFile` opened
    ///   (`secrets.load` protects that file from the browser), in the same
    ///   hold of ``BrowserReplFileSandbox/pathChangeLock`` as the open; it
    ///   must not take that lock. An error it throws fails the read, with
    ///   nothing read.
    func perform(
        _ operation: String,
        arguments: [String: Any],
        copyContents: ((Data) throws -> Data)?,
        opened: ((BrowserReplFileIdentity) throws -> Void)? = nil
    ) -> Result<Any, BrowserReplFileSystemError> {
        do {
            return .success(try run(operation, arguments, copyContents: copyContents, opened: opened))
        } catch let error as BrowserReplFileSystemError {
            return .failure(error)
        } catch {
            return .failure(Self.translate(error, operation: operation, path: arguments["path"] as? String ?? ""))
        }
    }

    /// The roots `fs` reaches: the working directory, then the session's
    /// temporary directory.
    private var roots: [String] {
        [sandbox.root] + (temporaryRoot.map { [$0] } ?? [])
    }

    private func run(
        _ operation: String,
        _ arguments: [String: Any],
        copyContents: ((Data) throws -> Data)?,
        opened: ((BrowserReplFileIdentity) throws -> Void)?
    ) throws -> Any {
        // Every path is bounded before it is normalized, canonicalized or walked.
        let paths = try writeBudget.holdPaths(["path", "from", "to"].compactMap { arguments[$0] as? String }, operation: operation)
        defer { writeBudget.releasePaths(paths) }
        func raw(_ key: String) throws -> String {
            guard let value = arguments[key] as? String else {
                throw BrowserReplFileSystemError(code: "EINVAL", message: "EINVAL: missing '\(key)'")
            }
            return value
        }
        func locate(
            _ access: BrowserReplFileSandbox.Access,
            key: String = "path",
            followingLastLink: Bool = true,
            creatingDirectories: Bool = false
        ) throws -> Location {
            try self.locate(try raw(key), for: access, followingLastLink: followingLastLink, creatingDirectories: creatingDirectories)
        }

        switch operation {
        case "resolve":
            return try sandbox.resolve(try raw("path"), for: .read, additionalRoots: Array(roots.dropFirst()))
        case "exists":
            guard let location = try? locate(.read) else { return false }
            return (try? location.status()) != nil
        case "readFile":
            let display = try raw("path")
            let (file, size) = try openFile(try locate(.read), display: display, opened: opened)
            guard size <= Self.maxReadFileBytes else { throw Self.fileTooLarge(size) }
            do {
                let data = try readAll(file, display: display)
                // A secrets.load that protected the file while it was read.
                if opened == nil { try Self.refuseSecretSource(file, display: display, syscall: "read") }
                return try data.browserReplBase64EncodedString(isCancelled: isCancelled)
            } catch is CancellationError {
                throw Self.cancelledError(syscall: "read", display: display)
            }
        case "writeFile":
            let display = try raw("path")
            let data: Data
            do {
                data = try Data(browserReplBase64: arguments["base64"] as? String ?? "", isCancelled: isCancelled) ?? Data()
            } catch {
                throw Self.cancelledError(syscall: "write", display: display)
            }
            let location = try locate(.write)
            guard let name = location.name else { throw Self.isDirectoryError }
            let append = arguments["append"] as? Bool == true
            // Refused before the file is opened, so an existing file is kept.
            // A new file is an entry change; writing or appending to one
            // that is there (an output spill file, line by line) is not.
            if (try? location.status()) == nil { try writeBudget.takeEntryChange(syscall: "write", display: display) }
            try writeBudget.take(data.count, syscall: "write", display: display)
            // Truncated only once it is known to be a regular file.
            let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY | (append ? O_APPEND : 0)
            let (descriptor, number) = try location.withinRoot(syscall: "open", display: display) { fd in
                let opened = openat(fd, name, flags, 0o666)
                return (opened, errno)
            }
            guard descriptor >= 0 else {
                // A FIFO without a reader (ENXIO) or a socket.
                if number == ENXIO || number == EOPNOTSUPP { throw Self.notRegularFile(display, syscall: "open") }
                throw Self.posixError(number, syscall: "open", display: display)
            }
            let file = BrowserReplDescriptor(descriptor)
            try Self.requireRegularFile(file, display: display, syscall: "open")
            if !append, ftruncate(file.fd, 0) != 0 { throw Self.posixError(errno, syscall: "open", display: display) }
            try writeAll(data, to: file, display: display)
            return NSNull()
        case "mkdir":
            let display = try raw("path")
            let recursive = arguments["recursive"] as? Bool ?? false
            let location = try locate(.write, creatingDirectories: recursive)
            guard let name = location.name else {
                if recursive { return NSNull() }
                throw BrowserReplFileSystemError(code: "EEXIST", message: "EEXIST: file already exists, mkdir '\(display)'")
            }
            try writeBudget.takeEntryChange(syscall: "mkdir", display: display)
            let made = try location.withinRoot(syscall: "mkdir", display: display) { fd in
                mkdirat(fd, name, 0o777) == 0 ? 0 : errno
            }
            if made != 0 {
                let number = made
                if number == EEXIST, recursive, (try? location.status())?.isDirectory == true { return NSNull() }
                throw Self.posixError(number, syscall: "mkdir", display: display)
            }
            return NSNull()
        case "readdir":
            let display = try raw("path")
            let directory = try openDirectory(try locate(.read), display: display)
            let entries = try Self.entries(of: directory, display: display, isCancelled: isCancelled, limit: Self.maxDirectoryEntries)
            return entries.map { entry -> [String: Any] in
                ["name": entry.name, "type": entry.type]
            }
        case "stat":
            return statResult(try locate(.read).status(display: try raw("path")))
        case "lstat":
            return statResult(try locate(.read, followingLastLink: false).status(display: try raw("path")))
        case "rm":
            let display = try raw("path")
            let location = try locate(.write, followingLastLink: false)
            guard let name = location.name, !isRoot(location) else {
                throw BrowserReplFileSystemError(code: "EACCES", message: "EACCES: refusing to remove the REPL working directory")
            }
            let force = arguments["force"] as? Bool ?? false
            try writeBudget.takeEntryChange(syscall: "rm", display: display)
            let status: FileStatus
            do {
                status = try location.status(display: display, syscall: "rm")
            } catch let error as BrowserReplFileSystemError where force && error.code == "ENOENT" {
                return NSNull()
            }
            if status.isDirectory {
                if arguments["recursive"] as? Bool == true {
                    try Self.removeTree(in: location.directory, name: name, root: location.root, display: display, budget: writeBudget, isCancelled: isCancelled)
                } else {
                    let removed = try location.withinRoot(syscall: "rm", display: display) { unlinkat($0, name, AT_REMOVEDIR) == 0 ? 0 : errno }
                    if removed != 0 { throw Self.posixError(removed, syscall: "rm", display: display) }
                }
            } else {
                // A link or file: remove the entry, never what a link points to.
                let removed = try location.withinRoot(syscall: "rm", display: display) { unlinkat($0, name, 0) == 0 ? 0 : errno }
                if removed != 0 { throw Self.posixError(removed, syscall: "rm", display: display) }
            }
            return NSNull()
        case "rename":
            // renameat(2) moves the entry itself (a link stays a link) and
            // replaces an existing destination atomically.
            let from = try locate(.write, key: "from", followingLastLink: false)
            let to = try locate(.write, key: "to", followingLastLink: false)
            // Like rm: the working directory and the temporary root are never
            // moved away or replaced.
            guard let fromName = from.name, let toName = to.name, !isRoot(from), !isRoot(to) else {
                throw BrowserReplFileSystemError(code: "EACCES", message: "EACCES: refusing to move or replace the REPL working directory")
            }
            try writeBudget.takeEntryChange(syscall: "rename", display: "\(try raw("from"))' -> '\(try raw("to"))")
            // A browser file navigation checks paths and takes its read
            // access under this lock (BrowserReplFileSandbox.withPinnedFileAccess).
            // Both directories must still be inside their roots: another
            // session may have moved one out since the walk opened it.
            let pair = "\(try raw("from"))' -> '\(try raw("to"))"
            let renamed: Int32 = try BrowserReplFileSandbox.pathChangeLock.withLock {
                for location in [from, to] {
                    if let root = location.root, root !== location.directory, !Self.isInside(location.directory, root: root) {
                        throw Self.movedOutOfRoot(syscall: "rename", display: pair)
                    }
                }
                return renameat(from.directory.fd, fromName, to.directory.fd, toName) == 0 ? 0 : errno
            }
            guard renamed == 0 else {
                throw Self.posixError(renamed, syscall: "rename", display: "\(try raw("from"))' -> '\(try raw("to"))")
            }
            return NSNull()
        case "copyFile":
            let fromDisplay = try raw("from")
            let pair = "\(fromDisplay)' -> '\(try raw("to"))"
            let (source, size) = try openFile(try locate(.read, key: "from"), display: fromDisplay, syscall: "copyfile")
            let destination = try locate(.write, key: "to")
            guard let name = destination.name else { throw Self.isDirectoryError }
            // A filtered copy is read whole first (secrets are masked across
            // the whole file), so it is bounded like readFile.
            let contents: Data? = try copyContents.map { filter in
                guard size <= Self.maxReadFileBytes else { throw Self.filteredCopyTooLarge(size) }
                let data: Data
                do {
                    data = try readAll(source, display: fromDisplay)
                } catch let error as BrowserReplFileSystemError where error.code == "ERR_FS_FILE_TOO_LARGE" {
                    throw Self.filteredCopyTooLarge(size)
                }
                return try filter(data)
            }
            if (try? destination.status()) == nil { try writeBudget.takeEntryChange(syscall: "copyfile", display: pair) }
            try writeBudget.take(contents?.count ?? size, syscall: "copyfile", display: pair)
            // Copy next to the destination, then swap it in, so a failed copy
            // leaves an existing destination untouched.
            let staging = ".\(name).cmux-copy-\(UUID().uuidString)"
            let (descriptor, number) = try destination.withinRoot(syscall: "copyfile", display: pair) { fd in
                let opened = openat(fd, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
                return (opened, errno)
            }
            guard descriptor >= 0 else { throw Self.posixError(number, syscall: "copyfile", display: pair) }
            let copy = BrowserReplDescriptor(descriptor)
            var skipped: [(name: String, size: Int)] = []
            do {
                if let contents {
                    try writeAll(contents, to: copy, display: pair)
                } else {
                    try copyData(from: source, to: copy, size: size, display: pair)
                }
                // Extended attributes through the write budget, then mode
                // and times as fcopyfile's own copy.
                skipped = try copyExtendedAttributes(from: source, to: copy, callBytes: contents?.count ?? size, display: pair)
                guard fcopyfile(source.fd, copy.fd, nil, copyfile_flags_t(COPYFILE_STAT)) == 0 else {
                    throw Self.posixError(errno, syscall: "copyfile", display: pair)
                }
                // A secrets.load that protected the source while it was copied.
                try Self.refuseSecretSource(source, display: fromDisplay, syscall: "copyfile")
                try Self.publish(staging, as: name, in: destination, holding: copy, display: pair)
            } catch {
                // Left in place when its directory was moved out of the root.
                _ = try? destination.withinRoot(syscall: "copyfile", display: pair) { unlinkat($0, staging, 0) }
                throw error
            }
            guard !skipped.isEmpty else { return NSNull() }
            // The runtime prints each as a warning line in the cell's output.
            return ["warnings": skipped.map { attribute in
                "fs.copyFile: left out the extended attribute \(attribute.name) (\(attribute.size) bytes), larger than the 1 MiB fs.copyFile copies, copyfile '\(pair)'"
            }]
        default:
            throw BrowserReplFileSystemError(code: "EINVAL", message: "EINVAL: unsupported fs operation '\(operation)'")
        }
    }

    /// Renames the staging entry `staging` in `directory` to `name` while
    /// it is still the regular file `copy` holds open, checked and renamed
    /// while no REPL `fs.rename` and no browser file grant runs
    /// (``BrowserReplFileSandbox/pathChangeLock``). The staging name is
    /// visible to another session sharing the directory, which can move a
    /// link into its place while the copy runs; `fs.rename` is the only
    /// fs operation that puts a link at a path, and it takes the same
    /// lock, so the entry checked is the one renamed, and a link is never
    /// published under the destination's name. Nor is anything published
    /// once another session moved the directory out of the root.
    private static func publish(
        _ staging: String,
        as name: String,
        in destination: Location,
        holding copy: BrowserReplDescriptor,
        display: String
    ) throws {
        let directory = destination.directory
        let result: Int32 = try BrowserReplFileSandbox.pathChangeLock.withLock {
            if let root = destination.root, root !== directory, !isInside(directory, root: root) {
                throw movedOutOfRoot(syscall: "copyfile", display: display)
            }
            var held = stat()
            var named = stat()
            guard fstat(copy.fd, &held) == 0, fstatat(directory.fd, staging, &named, AT_SYMLINK_NOFOLLOW) == 0 else { return errno }
            guard named.st_mode & S_IFMT == S_IFREG, named.st_dev == held.st_dev, named.st_ino == held.st_ino else { return EBUSY }
            return renameat(directory.fd, staging, directory.fd, name) == 0 ? 0 : errno
        }
        guard result != EBUSY else {
            throw BrowserReplFileSystemError(
                code: "EBUSY",
                message: "EBUSY: resource busy, copyfile '\(display)': the copy's staging file was replaced while it was written (another session shares the directory); copy again"
            )
        }
        guard result == 0 else { throw posixError(result, syscall: "copyfile", display: display) }
    }

    private static let isDirectoryError = BrowserReplFileSystemError(
        code: "EISDIR",
        message: "EISDIR: illegal operation on a directory, read"
    )

    // MARK: - Locating entries

    /// Where a path leads: the open directory that holds its last entry and
    /// the entry's name, or a root itself (`name == nil`, `directory` is the
    /// root). The entry may not exist yet.
    struct Location {
        let directory: BrowserReplDescriptor
        let name: String?
        /// The root the walk reached `directory` from, or nil for a file
        /// outside the roots the sandbox lets the session read (a download).
        let root: BrowserReplDescriptor?

        /// The entry's status, not following a link.
        func status(display: String = "", syscall: String = "stat") throws -> FileStatus {
            var info = stat()
            let (result, number) = try withinRoot(syscall: syscall, display: display) { fd in
                let done = name.map { fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) } ?? fstat(fd, &info)
                return (done, errno)
            }
            guard result == 0 else { throw BrowserReplFileSystem.posixError(number, syscall: syscall, display: display) }
            return FileStatus(info)
        }

        /// Runs `sink` on `directory`'s descriptor while it is inside its
        /// root (``BrowserReplFileSystem/withinRoot(_:root:syscall:display:_:)``).
        func withinRoot<T>(syscall: String, display: String, alwaysLocked: Bool = false, _ sink: (Int32) throws -> T) throws -> T {
            try BrowserReplFileSystem.withinRoot(directory, root: root, syscall: syscall, display: display, alwaysLocked: alwaysLocked, sink)
        }
    }

    /// Runs `sink`, a system call relative to `directory`, while no REPL
    /// `fs.rename` runs (``BrowserReplFileSandbox/pathChangeLock``) and
    /// once `directory` is still `root` or below it, or throws `EACCES`
    /// without running it: another session that shares the tree moved the
    /// directory out of the root since the walk opened it. With no root
    /// (a file the sandbox lets the session read by its path), or for the
    /// root itself, `sink` runs as it is, under the lock only when
    /// `alwaysLocked`. The caller must not hold the lock.
    static func withinRoot<T>(
        _ directory: BrowserReplDescriptor,
        root: BrowserReplDescriptor?,
        syscall: String,
        display: String,
        alwaysLocked: Bool = false,
        _ sink: (Int32) throws -> T
    ) throws -> T {
        guard let root, root !== directory else {
            return alwaysLocked ? try BrowserReplFileSandbox.pathChangeLock.withLock { try sink(directory.fd) } : try sink(directory.fd)
        }
        return try BrowserReplFileSandbox.pathChangeLock.withLock {
            guard isInside(directory, root: root) else { throw movedOutOfRoot(syscall: syscall, display: display) }
            return try sink(directory.fd)
        }
    }

    /// Whether `directory` is `root` or a directory below it now: a walk up
    /// its `..` entries reaches `root` (same device and inode) before `/`.
    /// Call while no REPL rename runs (``BrowserReplFileSandbox/pathChangeLock``).
    /// A step that fails, or a chain deeper than any path, counts as outside.
    static func isInside(_ directory: BrowserReplDescriptor, root: BrowserReplDescriptor) -> Bool {
        var rootInfo = stat()
        guard fstat(root.fd, &rootInfo) == 0 else { return false }
        var current = directory
        for _ in 0..<maxAncestorSteps {
            var info = stat()
            guard fstat(current.fd, &info) == 0 else { return false }
            if info.st_dev == rootInfo.st_dev, info.st_ino == rootInfo.st_ino { return true }
            let parent = openat(current.fd, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parent >= 0 else { return false }
            let next = BrowserReplDescriptor(parent)
            var parentInfo = stat()
            // `/` is its own parent.
            guard fstat(next.fd, &parentInfo) == 0,
                  parentInfo.st_dev != info.st_dev || parentInfo.st_ino != info.st_ino else { return false }
            current = next
        }
        return false
    }

    /// The most `..` steps ``isInside(_:root:)`` takes: a path of at most
    /// `PATH_MAX` bytes has fewer components.
    private static let maxAncestorSteps = Int(PATH_MAX) / 2

    static func movedOutOfRoot(syscall: String, display: String) -> BrowserReplFileSystemError {
        BrowserReplFileSystemError(
            code: "EACCES",
            message: "EACCES: permission denied, \(syscall) '\(display)': its directory was moved out of the REPL working directory while the call ran (another session shares the directory)"
        )
    }

    /// The fields of a `stat` the REPL reports.
    struct FileStatus {
        let info: stat

        init(_ info: stat) {
            self.info = info
        }

        var isDirectory: Bool { (info.st_mode & S_IFMT) == S_IFDIR }

        var type: String {
            switch info.st_mode & S_IFMT {
            case S_IFREG: return "file"
            case S_IFDIR: return "directory"
            case S_IFLNK: return "symlink"
            default: return "other"
            }
        }

        func isSameFile(as other: FileStatus) -> Bool {
            info.st_dev == other.info.st_dev && info.st_ino == other.info.st_ino
        }
    }

    /// The most links one path may follow, as `MAXSYMLINKS`.
    private static let maxLinksFollowed = 32

    /// Finds where `path` leads for `access`, walking from a root's
    /// descriptor. Relative paths start at the sandbox root; absolute paths
    /// and `..` must stay inside a root (or name a file the sandbox allows
    /// reading, for `read`). With `followingLastLink`, a link in the last
    /// component is followed like the others; without it, the location is
    /// the link itself. `creatingDirectories` creates missing directories
    /// on the way (`mkdir -p`).
    private func locate(
        _ path: String,
        for access: BrowserReplFileSandbox.Access,
        followingLastLink: Bool,
        creatingDirectories: Bool
    ) throws -> Location {
        guard !path.isEmpty, !path.contains("\u{0}") else {
            throw BrowserReplFileSystemError(code: "EINVAL", message: "EINVAL: invalid path '\(path)'")
        }
        let normalized = BrowserReplFileSandbox.lexicallyNormalized(path.hasPrefix("/") ? path : sandbox.root + "/" + path)
        let hint = followingLastLink
            ? BrowserReplFileSandbox.canonicalize(normalized)
            : BrowserReplFileSandbox.entryPath(normalized)
        if let (root, components) = rootAndComponents(normalized) ?? rootAndComponents(hint) {
            return try walk(
                from: root,
                components: components,
                display: path,
                followingLastLink: followingLastLink,
                creatingDirectories: creatingDirectories
            )
        }
        if access == .read, sandbox.allowsReading(hint) {
            return try walkWithoutLinks(hint, display: path)
        }
        throw BrowserReplFileSystemError.escape(path)
    }

    /// The root `path` (absolute, normalized) is under, and its components
    /// below that root, or nil.
    private func rootAndComponents(_ path: String) -> (root: Int, components: [String])? {
        for (index, root) in roots.enumerated() {
            if path == root { return (index, []) }
            let prefix = root == "/" ? "/" : root + "/"
            if path.hasPrefix(prefix) {
                return (index, path.dropFirst(prefix.count).split(separator: "/").map(String.init))
            }
        }
        return nil
    }

    /// The root's directory: the one held open since the fs first opened
    /// it, so renaming the root's path away, or putting a link or another
    /// directory in its place, changes nothing for this fs. It is opened,
    /// and with `creating` (only `mkdir -p` creates a working directory that
    /// does not exist yet) made, by a walk from `/` that follows no link,
    /// so a parent another session swapped for a link since the root was
    /// resolved is never followed.
    private func openRoot(_ index: Int, creating: Bool) throws -> BrowserReplDescriptor {
        let root = roots[index]
        if let held = rootDirectories.descriptor(at: index, for: root) { return held }
        let descriptor = BrowserReplRootDirectories.open(root, creating: creating)
        guard descriptor >= 0 else {
            let number = errno
            if number == ELOOP {
                throw BrowserReplFileSystemError(
                    code: "EACCES",
                    message: "EACCES: permission denied, the REPL working directory '\(root)' is now reached through a symbolic link, which fs never follows out of it; run the command again from the directory itself"
                )
            }
            throw Self.posixError(number, syscall: "open", display: root)
        }
        return rootDirectories.hold(BrowserReplDescriptor(descriptor), at: index, for: root)
    }

    /// Whether `location` is a root, or an entry that is one (reached
    /// through another root or a link to it).
    private func isRoot(_ location: Location) -> Bool {
        guard location.name != nil else { return true }
        guard let entry = try? location.status() else { return false }
        return roots.indices.contains { index in
            guard let root = try? openRoot(index, creating: false),
                  let status = try? Location(directory: root, name: nil, root: root).status() else { return false }
            return status.isSameFile(as: entry)
        }
    }

    private func walk(
        from rootIndex: Int,
        components: [String],
        display: String,
        followingLastLink: Bool,
        creatingDirectories: Bool
    ) throws -> Location {
        var root = rootIndex
        var directory = try openRoot(root, creating: creatingDirectories)
        // The descriptor of the root the walk is under now.
        var rootDirectory = directory
        // The directories below the root that `directory` is, by name.
        var names: [String] = []
        // Components still to walk, the next one last.
        var pending = Array(components.reversed())
        var linksFollowed = 0

        func reopen() throws {
            var current = try openRoot(root, creating: false)
            for name in names {
                let next = openat(current.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.posixError(errno, syscall: "open", display: display) }
                current = BrowserReplDescriptor(next)
            }
            directory = current
        }
        func location(_ name: String?) -> Location {
            Location(directory: directory, name: name, root: rootDirectory)
        }

        while let component = pending.popLast() {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                // `..` above a root leaves it.
                guard !names.isEmpty else { throw BrowserReplFileSystemError.escape(display) }
                names.removeLast()
                try reopen()
                continue
            }
            let isLast = pending.allSatisfy { $0.isEmpty || $0 == "." }
            if isLast, !followingLastLink {
                return location(component)
            }
            var info = stat()
            if fstatat(directory.fd, component, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                let number = errno
                guard number == ENOENT else { throw Self.posixError(number, syscall: "open", display: display) }
                if isLast { return location(component) }
                guard creatingDirectories else { throw Self.posixError(ENOENT, syscall: "open", display: display) }
                try writeBudget.takeEntryChange(syscall: "mkdir", display: display)
                let made = try location(component).withinRoot(syscall: "mkdir", display: display) { fd in
                    mkdirat(fd, component, 0o777) == 0 ? 0 : errno
                }
                if made != 0, made != EEXIST {
                    throw Self.posixError(made, syscall: "mkdir", display: display)
                }
                pending.append(component)
                continue
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                linksFollowed += 1
                guard linksFollowed <= Self.maxLinksFollowed else { throw Self.posixError(ELOOP, syscall: "open", display: display) }
                let target = try Self.readLink(in: directory, name: component, display: display)
                if target.hasPrefix("/") {
                    // An absolute target must lead into a root; the walk
                    // starts again there.
                    let normalized = BrowserReplFileSandbox.lexicallyNormalized(target)
                    guard let (next, below) = rootAndComponents(normalized)
                        ?? rootAndComponents(BrowserReplFileSandbox.canonicalize(normalized)) else {
                        throw BrowserReplFileSystemError.escape(display)
                    }
                    root = next
                    names = []
                    directory = try openRoot(root, creating: false)
                    rootDirectory = directory
                    pending.append(contentsOf: below.reversed())
                } else {
                    pending.append(contentsOf: target.split(separator: "/", omittingEmptySubsequences: true).map(String.init).reversed())
                }
                continue
            }
            if isLast { return location(component) }
            let next = openat(directory.fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                let number = errno
                // It became a link since the fstatat: look again.
                if number == ELOOP, linksFollowed < Self.maxLinksFollowed {
                    linksFollowed += 1
                    pending.append(component)
                    continue
                }
                throw Self.posixError(number, syscall: "open", display: display)
            }
            directory = BrowserReplDescriptor(next)
            names.append(component)
        }
        // The path names a directory the walk is in: a root, or one below it.
        guard let last = names.popLast() else { return location(nil) }
        try reopen()
        return location(last)
    }

    /// Walks a canonical path the sandbox allows reading (a download outside
    /// the roots), following no link on the way.
    private func walkWithoutLinks(_ path: String, display: String) throws -> Location {
        var components = path.split(separator: "/").map(String.init)
        guard let name = components.popLast() else { throw BrowserReplFileSystemError.escape(display) }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError(errno, syscall: "open", display: display) }
        var directory = BrowserReplDescriptor(descriptor)
        for component in components {
            descriptor = openat(directory.fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw Self.posixError(errno, syscall: "open", display: display) }
            directory = BrowserReplDescriptor(descriptor)
        }
        return Location(directory: directory, name: name, root: nil)
    }

    private static func readLink(in directory: BrowserReplDescriptor, name: String, display: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(directory.fd, name, &buffer, buffer.count - 1)
        guard count >= 0 else { throw posixError(errno, syscall: "readlink", display: display) }
        return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Files and directories

    /// Opens the regular file at `location` for reading and returns its
    /// size. `O_NONBLOCK` keeps a FIFO from waiting for a writer; anything
    /// but a regular file then fails (`EISDIR` for a directory, `EINVAL`).
    ///
    /// - Parameter opened: Told the identity of the regular file opened
    ///   (one ``maxReadFileBytes`` or smaller) in the same hold of
    ///   ``BrowserReplFileSandbox/pathChangeLock`` as the open, also for a
    ///   file directly in a root: a file navigation checks and starts its
    ///   load under that lock, so it runs wholly before the open or after
    ///   `opened` returned, never between (`secrets.load` protects the file
    ///   there, ``BrowserReplSecretSources``). It must not take that lock.
    private func openFile(
        _ location: Location,
        display: String,
        syscall: String = "open",
        opened: ((BrowserReplFileIdentity) throws -> Void)? = nil
    ) throws -> (BrowserReplDescriptor, Int) {
        guard let name = location.name else { throw Self.isDirectoryError }
        let (descriptor, number) = try location.withinRoot(syscall: syscall, display: display, alwaysLocked: opened != nil) { fd in
            let descriptor = openat(fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | O_NOCTTY)
            let number = errno
            var info = stat()
            if let opened, descriptor >= 0, fstat(descriptor, &info) == 0,
               info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) <= Self.maxReadFileBytes {
                // The volume id from the same descriptor, so reclaiming the
                // protection asks the volume that holds this file.
                var volumeInfo = statfs()
                let volume = fstatfs(descriptor, &volumeInfo) == 0 ? volumeInfo.f_fsid : nil
                do {
                    try opened(BrowserReplFileIdentity(info, volume: volume))
                } catch {
                    close(descriptor)
                    throw error
                }
            }
            return (descriptor, number)
        }
        guard descriptor >= 0 else {
            if number == ENXIO || number == EOPNOTSUPP { throw Self.notRegularFile(display, syscall: syscall) }
            throw Self.posixError(number, syscall: syscall, display: display)
        }
        let file = BrowserReplDescriptor(descriptor)
        let size = try Self.requireRegularFile(file, display: display, syscall: syscall)
        if opened == nil { try Self.refuseSecretSource(file, display: display, syscall: syscall) }
        return (file, size)
    }

    /// Fails with `denied` when the open `file` is one `secrets.load` read
    /// (``BrowserReplSecretSources``), under any name and for every session,
    /// the one that loaded it too: only the loading session knows its
    /// values to mask them, and only `secrets.load` (the read with
    /// `opened`) reads it. `stat`, `lstat`, `exists` and `readdir` still
    /// see it. A read checks once it opened the file and again once it read
    /// it (a copy before it publishes), so a `secrets.load` of the same file
    /// meanwhile fails the read too.
    private static func refuseSecretSource(_ file: BrowserReplDescriptor, display: String, syscall: String) throws {
        var info = stat()
        guard fstat(file.fd, &info) == 0 else { throw posixError(errno, syscall: syscall, display: display) }
        guard BrowserReplSecretSources.shared.contains(BrowserReplFileIdentity(info)) else { return }
        throw BrowserReplFileSystemError(
            code: "denied",
            message: "denied: '\(display)' holds secrets loaded by secrets.load, so fs does not read or copy it in any session (only secrets.load reads it; stat and readdir still see it), \(syscall) '\(display)'"
        )
    }

    /// The size of the open regular file; anything else fails.
    @discardableResult
    private static func requireRegularFile(_ file: BrowserReplDescriptor, display: String, syscall: String) throws -> Int {
        var info = stat()
        guard fstat(file.fd, &info) == 0 else { throw posixError(errno, syscall: syscall, display: display) }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return Int(info.st_size)
        case S_IFDIR: throw isDirectoryError
        default: throw notRegularFile(display, syscall: syscall)
        }
    }

    private static func notRegularFile(_ display: String, syscall: String) -> BrowserReplFileSystemError {
        BrowserReplFileSystemError(
            code: "EINVAL",
            message: "EINVAL: not a regular file (a FIFO, socket or device), \(syscall) '\(display)'"
        )
    }

    private static func fileTooLarge(_ size: Int) -> BrowserReplFileSystemError {
        BrowserReplFileSystemError(
            code: "ERR_FS_FILE_TOO_LARGE",
            message: "File size (\(size)) is greater than 64 MiB, the most fs.readFile reads; copy it with fs.copyFile or read it in a tab"
        )
    }

    /// Why a copy whose contents the session masks refused a large source.
    private static func filteredCopyTooLarge(_ size: Int) -> BrowserReplFileSystemError {
        BrowserReplFileSystemError(
            code: "ERR_FS_FILE_TOO_LARGE",
            message: "File size (\(size)) is greater than 64 MiB, the most fs.copyFile copies while secrets are masked (it reads the file whole to mask them); download or save it in a tab instead"
        )
    }

    /// Reads the file to its end; past `maxReadFileBytes` (a file that grew
    /// after its size was checked) it fails. It runs on the session's
    /// JavaScript thread, so it stops with `ECANCELED` between chunks when
    /// the call is cancelled (the cell timed out, the session closed).
    private func readAll(_ file: BrowserReplDescriptor, display: String) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            if !data.isEmpty, isCancelled() { throw Self.cancelledError(syscall: "read", display: display) }
            let count = read(file.fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.posixError(errno, syscall: "read", display: display)
            }
            if count == 0 { return data }
            guard data.count + count <= Self.maxReadFileBytes else { throw Self.fileTooLarge(data.count + count) }
            data.append(buffer, count: count)
        }
    }

    /// How much a long write or copy writes between checks for cancellation.
    static let chunkBytes = 1 << 20

    /// Writes `data` in chunks, stopping when the call is cancelled.
    private func writeAll(_ data: Data, to file: BrowserReplDescriptor, display: String) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                if offset > 0, isCancelled() { throw Self.cancelledError(syscall: "write", display: display) }
                let count = write(file.fd, bytes.baseAddress! + offset, min(bytes.count - offset, Self.chunkBytes))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError(errno, syscall: "write", display: display)
                }
                offset += count
            }
        }
    }

    /// Copies `source`'s bytes to `destination` in chunks, stopping when the
    /// call is cancelled. `size` was taken from the write budget; a source
    /// that grows meanwhile takes the rest as it is read, up to one call's
    /// limit.
    private func copyData(from source: BrowserReplDescriptor, to destination: BrowserReplDescriptor, size: Int, display: String) throws {
        var buffer = [UInt8](repeating: 0, count: Self.chunkBytes)
        var copied = 0
        while true {
            if copied > 0, isCancelled() { throw Self.cancelledError(syscall: "copyfile", display: display) }
            let count = read(source.fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.posixError(errno, syscall: "copyfile", display: display)
            }
            if count == 0 { return }
            if copied + count > size {
                try writeBudget.take(copied + count - max(size, copied), syscall: "copyfile", display: display, callBytes: copied + count)
            }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = write(destination.fd, bytes.baseAddress! + offset, count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw Self.posixError(errno, syscall: "copyfile", display: display)
                    }
                    offset += written
                }
            }
            copied += count
        }
    }

    /// The largest extended attribute copyFile copies, 1 MiB: each is read
    /// whole in one system call that nothing stops midway.
    static let maxExtendedAttributeBytes = 1 << 20

    /// Copies `source`'s extended attributes to `destination`, as
    /// `COPYFILE_XATTR` does, but each one's bytes are taken from the write
    /// budget as part of the call (`callBytes` already written) and the
    /// copy stops with `ECANCELED` between attributes when the call is
    /// cancelled. One past ``maxExtendedAttributeBytes`` is left out, not
    /// read, and returned, so the caller can say so. Attributes the
    /// destination refuses (protected system ones) are left out silently,
    /// as `copyfile` leaves them.
    /// - Returns: The attributes left out for their size.
    private func copyExtendedAttributes(
        from source: BrowserReplDescriptor,
        to destination: BrowserReplDescriptor,
        callBytes: Int,
        display: String
    ) throws -> [(name: String, size: Int)] {
        var skipped: [(name: String, size: Int)] = []
        let listSize = flistxattr(source.fd, nil, 0, 0)
        if listSize < 0 {
            if errno == ENOTSUP { return skipped }
            throw Self.posixError(errno, syscall: "copyfile", display: display)
        }
        guard listSize > 0 else { return skipped }
        var list = [CChar](repeating: 0, count: listSize)
        let listed = flistxattr(source.fd, &list, listSize, 0)
        guard listed >= 0 else { throw Self.posixError(errno, syscall: "copyfile", display: display) }
        let names = list.prefix(listed).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        var written = callBytes
        for name in names {
            if isCancelled() { throw Self.cancelledError(syscall: "copyfile", display: display) }
            let size = fgetxattr(source.fd, name, nil, 0, 0, 0)
            if size < 0 {
                if errno == ENOATTR { continue }
                throw Self.posixError(errno, syscall: "copyfile", display: display)
            }
            guard size <= Self.maxExtendedAttributeBytes else {
                skipped.append((name, size))
                continue
            }
            written += size
            try writeBudget.take(size, syscall: "copyfile", display: display, callBytes: written)
            var value = [UInt8](repeating: 0, count: max(size, 1))
            let read = fgetxattr(source.fd, name, &value, size, 0, 0)
            if read < 0 {
                if errno == ENOATTR { continue }
                throw Self.posixError(errno, syscall: "copyfile", display: display)
            }
            if fsetxattr(destination.fd, name, value, read, 0, 0) != 0 {
                switch errno {
                case ENOTSUP, EPERM, EACCES: continue
                default: throw Self.posixError(errno, syscall: "copyfile", display: display)
                }
            }
        }
        return skipped
    }

    /// Why a call stopped part way; `display` is the path, or empty when
    /// the caller (the egress gate's scan) does not know it.
    static func cancelledError(syscall: String, display: String) -> BrowserReplFileSystemError {
        BrowserReplFileSystemError(
            code: "ECANCELED",
            message: "ECANCELED: operation canceled because its cell timed out or the session ended, \(syscall)" + (display.isEmpty ? "" : " '\(display)'")
        )
    }

    /// Opens the directory at `location` for listing.
    private func openDirectory(_ location: Location, display: String) throws -> BrowserReplDescriptor {
        guard let name = location.name else {
            let copy = dup(location.directory.fd)
            guard copy >= 0 else { throw Self.posixError(errno, syscall: "scandir", display: display) }
            return BrowserReplDescriptor(copy)
        }
        let (descriptor, number) = try location.withinRoot(syscall: "scandir", display: display) { fd in
            let opened = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            return (opened, errno)
        }
        guard descriptor >= 0 else { throw Self.posixError(number, syscall: "scandir", display: display) }
        return BrowserReplDescriptor(descriptor)
    }

    /// How many entries `readdir` and `rm -r` handle between checks for
    /// cancellation.
    static let entriesPerCancellationCheck = 1024

    /// The entries of an open directory, by name, with their types (a link
    /// is a `symlink`). Stops with `ECANCELED` when `isCancelled` says so,
    /// checked every ``entriesPerCancellationCheck`` entries, and with
    /// `ERR_FS_DIR_TOO_LARGE` at the entry past `limit`.
    static func entries(
        of directory: BrowserReplDescriptor,
        display: String = "",
        isCancelled: () -> Bool = { false },
        limit: Int = .max
    ) throws -> [(name: String, type: String)] {
        try readEntries(of: directory, display: display, isCancelled: isCancelled, limit: limit, stopAtLimit: false)
            .sorted { $0.name < $1.name }
    }

    /// The first `count` entries an open directory lists now, in the order
    /// it lists them: a batch a recursive `rm` handles before it reads
    /// again, so it never holds a large directory's whole list.
    static func firstEntries(
        of directory: BrowserReplDescriptor,
        count: Int,
        display: String
    ) throws -> [(name: String, type: String)] {
        try readEntries(of: directory, display: display, isCancelled: { false }, limit: count, stopAtLimit: true)
    }

    private static func readEntries(
        of directory: BrowserReplDescriptor,
        display: String,
        isCancelled: () -> Bool,
        limit: Int,
        stopAtLimit: Bool
    ) throws -> [(name: String, type: String)] {
        let copy = dup(directory.fd)
        guard copy >= 0, let stream = fdopendir(copy) else {
            let number = errno
            if copy >= 0 { close(copy) }
            throw posixError(number, syscall: "scandir", display: "")
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [(name: String, type: String)] = []
        while let entry = readdir(stream) {
            if !result.isEmpty, result.count % entriesPerCancellationCheck == 0, isCancelled() {
                throw cancelledError(syscall: "scandir", display: display)
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            if stopAtLimit, result.count >= limit { break }
            guard result.count < limit else {
                throw BrowserReplFileSystemError(
                    code: "ERR_FS_DIR_TOO_LARGE",
                    message: "ERR_FS_DIR_TOO_LARGE: scandir '\(display)' has more than \(limit) entries, more than readdir lists; read a subdirectory, or move files into subdirectories"
                )
            }
            let type: String
            switch Int32(entry.pointee.d_type) {
            case DT_REG: type = "file"
            case DT_DIR: type = "directory"
            case DT_LNK: type = "symlink"
            case DT_UNKNOWN:
                type = (try? Location(directory: directory, name: name, root: nil).status().type) ?? "other"
            default: type = "other"
            }
            result.append((name, type))
        }
        return result
    }

    /// How many subdirectory names a recursive `rm` holds at once, over
    /// every level it is in, to remove before it lists their directory
    /// again.
    static let maximumPendingSubdirectories = 1024

    /// Removes directory `name` in `parent` and everything in it, following
    /// no link. Holds at most two directories open: it descends by name
    /// from `parent` with `O_NOFOLLOW` at each step, so a deep tree cannot
    /// use up descriptors. Stops with `ECANCELED` when `isCancelled` says
    /// so, checked every ``entriesPerCancellationCheck`` entries handled
    /// and directories opened together.
    ///
    /// It reads a directory ``entriesPerCancellationCheck`` entries at a
    /// time and handles each batch before it reads again (removed entries
    /// are no longer listed), keeping the names of at most
    /// ``maximumPendingSubdirectories`` subdirectories to descend into, so
    /// its memory does not grow with a directory's size and it lists each
    /// entry about once.
    ///
    /// Every entry it removes inside `name` is an entry change taken from
    /// `budget` before it is removed (`name` itself was taken by the
    /// caller); when the budget runs out it stops with `EDQUOT`, saying how
    /// many entries it removed, and leaves the rest.
    ///
    /// Each removal runs once its directory is still below `root`
    /// (``withinRoot(_:root:syscall:display:_:)``): a directory another
    /// session moves out of the root while the removal runs stops it with
    /// `EACCES`, and nothing more is removed there.
    private static func removeTree(
        in parent: BrowserReplDescriptor,
        name: String,
        root: BrowserReplDescriptor?,
        display: String,
        budget: BrowserReplWriteBudget,
        isCancelled: () -> Bool
    ) throws {
        var removed = 0
        func take() throws {
            do {
                try budget.takeEntryChange(syscall: "rm", display: display)
            } catch let error as BrowserReplFileSystemError {
                throw BrowserReplFileSystemError(
                    code: error.code,
                    message: "\(error.message) (the recursive rm stopped after removing \(removed) \(removed == 1 ? "entry" : "entries") inside it; the rest remain)"
                )
            }
        }
        // Work done: each entry handled and each directory opened on the
        // way down (an empty directory's ancestors are reopened at every
        // level, so a deep chain of them is work an entry count misses).
        var handled = 0
        func count() throws {
            handled += 1
            if handled % entriesPerCancellationCheck == 0, isCancelled() {
                throw cancelledError(syscall: "rm", display: display)
            }
        }
        func open(_ path: [String]) throws -> BrowserReplDescriptor {
            var current = parent
            for component in path {
                try count()
                let next = openat(current.fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posixError(errno, syscall: "rm", display: display) }
                current = BrowserReplDescriptor(next)
            }
            return current
        }
        // Each level: the directory's name and the subdirectories found in
        // its last batch that are still to be removed.
        var path: [(name: String, pending: [String])] = [(name, [])]
        var pendingCount = 0
        while let level = path.last {
            if let next = level.pending.last {
                path[path.count - 1].pending.removeLast()
                pendingCount -= 1
                path.append((next, []))
                continue
            }
            let names = path.map(\.name)
            let directory = try open(names)
            let batch = try firstEntries(of: directory, count: entriesPerCancellationCheck, display: display)
            guard !batch.isEmpty else {
                // Empty: remove it from the directory that holds it.
                let holder = try open(Array(names.dropLast()))
                // `name` itself was taken by the caller.
                if path.count > 1 { try take() }
                let result = try withinRoot(holder, root: root, syscall: "rm", display: display) { unlinkat($0, level.name, AT_REMOVEDIR) == 0 ? 0 : errno }
                if result != 0 {
                    guard result == ENOENT else { throw posixError(result, syscall: "rm", display: display) }
                } else if path.count > 1 {
                    removed += 1
                }
                path.removeLast()
                continue
            }
            var found: [String] = []
            for entry in batch {
                try count()
                if entry.type == "directory" {
                    // One more is always kept, so a batch of directories
                    // makes progress; the others are listed again later.
                    if found.isEmpty || pendingCount + found.count < maximumPendingSubdirectories {
                        found.append(entry.name)
                    }
                    continue
                }
                try take()
                let result = try withinRoot(directory, root: root, syscall: "rm", display: display) { unlinkat($0, entry.name, 0) == 0 ? 0 : errno }
                if result != 0 {
                    guard result == ENOENT else { throw posixError(result, syscall: "rm", display: display) }
                } else {
                    removed += 1
                }
            }
            path[path.count - 1].pending = found
            pendingCount += found.count
        }
    }

    /// `stat`/`lstat` fields.
    private func statResult(_ status: FileStatus) -> [String: Any] {
        let info = status.info
        let milliseconds = { (time: timespec) in Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000 }
        return [
            "size": Int64(info.st_size),
            "type": status.type,
            "mtimeMs": milliseconds(info.st_mtimespec),
            "birthtimeMs": milliseconds(info.st_birthtimespec),
        ]
    }

    /// A Node-style error for a failed system call, for example
    /// `ENOENT: no such file or directory, rename 'a' -> 'b'`.
    static func posixError(_ number: Int32, syscall: String, display: String) -> BrowserReplFileSystemError {
        let code: String
        switch number {
        case ENOENT: code = "ENOENT"
        case EEXIST: code = "EEXIST"
        case ENOTDIR: code = "ENOTDIR"
        case EISDIR: code = "EISDIR"
        case ENOTEMPTY: code = "ENOTEMPTY"
        case EACCES, EPERM: code = "EACCES"
        case EINVAL: code = "EINVAL"
        case ELOOP: code = "ELOOP"
        default: code = "EIO"
        }
        let reason = String(cString: strerror(number))
        let lowered = reason.prefix(1).lowercased() + reason.dropFirst()
        return BrowserReplFileSystemError(code: code, message: "\(code): \(lowered), \(syscall) '\(display)'")
    }

    static func translate(_ error: any Error, operation: String, path: String) -> BrowserReplFileSystemError {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix = underlying?.domain == NSPOSIXErrorDomain ? underlying?.code : (nsError.domain == NSPOSIXErrorDomain ? nsError.code : nil)
        let code: String
        switch (posix, nsError.code) {
        case (Int(ENOENT)?, _), (_, NSFileNoSuchFileError), (_, NSFileReadNoSuchFileError): code = "ENOENT"
        case (Int(EEXIST)?, _), (_, NSFileWriteFileExistsError): code = "EEXIST"
        case (Int(ENOTDIR)?, _): code = "ENOTDIR"
        case (Int(EISDIR)?, _): code = "EISDIR"
        case (Int(ENOTEMPTY)?, _): code = "ENOTEMPTY"
        case (Int(EACCES)?, _), (Int(EPERM)?, _), (_, NSFileReadNoPermissionError), (_, NSFileWriteNoPermissionError): code = "EACCES"
        default: code = "EIO"
        }
        return BrowserReplFileSystemError(code: code, message: "\(code): \(nsError.localizedDescription), \(operation) '\(path)'")
    }
}

/// What a session's fs may still write: at most `perCall` bytes in one
/// `writeFile` or `copyFile`, `perSession` in all over the session's life,
/// and `perSessionEntryChanges` changes to entries (a file created by a
/// write or copy, also an empty one, a directory made, an entry renamed or
/// removed), so agent code can fill neither the disk nor its entries.
/// Shared by the fs copies of one session. The counts live in the
/// session's ledger (``BrowserReplResource/fileBytesWritten``,
/// ``BrowserReplResource/fileEntryChanges``).
final class BrowserReplWriteBudget: @unchecked Sendable {
    /// The most one `writeFile` (also an append) or `copyFile` writes, 256 MiB.
    static let maximumBytesPerCall = BrowserReplResourceLimits.standard.each(.fileBytesWritten) ?? .max
    /// The most a session's fs writes over its life, 2 GiB.
    static let maximumBytesPerSession = BrowserReplResourceLimits.standard[.fileBytesWritten]
    /// The most entry changes a session's fs makes over its life.
    static let maximumEntryChangesPerSession = BrowserReplResourceLimits.standard[.fileEntryChanges]

    private let ledger: BrowserReplResourceLedger

    /// A budget of its own, outside a session.
    convenience init(
        perCall: Int = BrowserReplWriteBudget.maximumBytesPerCall,
        perSession: Int = BrowserReplWriteBudget.maximumBytesPerSession,
        perSessionEntryChanges: Int = BrowserReplWriteBudget.maximumEntryChangesPerSession
    ) {
        self.init(ledger: BrowserReplResourceLedger(limits: BrowserReplResourceLimits.unbounded
            .with(.fileBytesWritten, perSession)
            .with(.fileBytesWritten, each: perCall)
            .with(.fileEntryChanges, perSessionEntryChanges)
            .with(.fsPathBytes, each: BrowserReplResourceLimits.standard.each(.fsPathBytes))))
    }

    /// The session's budget, in its ledger.
    init(ledger: BrowserReplResourceLedger) {
        self.ledger = ledger
    }

    var perCall: Int { ledger.limits.each(.fileBytesWritten) ?? .max }

    /// Holds the paths one fs call names (``BrowserReplResource/fsPathBytes``)
    /// until it returns, or throws `ENAMETOOLONG` for one past the limit
    /// before any work; the message never repeats the path.
    /// - Returns: The bytes held, to ``releasePaths(_:)``.
    func holdPaths(_ paths: [String], operation: String) throws -> [Int] {
        var held: [Int] = []
        for path in paths {
            let bytes = path.utf8.count
            if let refusal = ledger.reserve(bytes, of: .fsPathBytes) {
                releasePaths(held)
                throw BrowserReplFileSystemError(code: "ENAMETOOLONG", message: "ENAMETOOLONG: \(refusal.message), \(operation)")
            }
            held.append(bytes)
        }
        return held
    }

    /// Releases what ``holdPaths(_:operation:)`` held.
    func releasePaths(_ held: [Int]) {
        for bytes in held { ledger.release(bytes, of: .fsPathBytes) }
    }

    /// Takes one entry change (a file created, a directory made,
    /// an entry renamed or removed) from the budget, or throws `EDQUOT`
    /// when the session made its limit of them.
    func takeEntryChange(syscall: String, display: String) throws {
        if let refusal = ledger.reserve(1, of: .fileEntryChanges) {
            throw BrowserReplFileSystemError(code: "EDQUOT", message: "EDQUOT: \(refusal.message), \(syscall) '\(display)'")
        }
    }

    /// Takes `count` bytes from the budget, or throws `EFBIG` when the call
    /// (`callBytes` in all, `count` by default) is past `perCall`, or
    /// `EDQUOT` when the session's budget is used up.
    func take(_ count: Int, syscall: String, display: String, callBytes: Int? = nil) throws {
        try checkCall(callBytes ?? count, syscall: syscall, display: display)
        // The call was checked whole above; a part of it is not one call.
        if let refusal = ledger.reserve(count, of: .fileBytesWritten, each: .max) {
            throw BrowserReplFileSystemError(code: "EDQUOT", message: "EDQUOT: \(refusal.message), \(syscall) '\(display)'")
        }
    }

    /// Takes a file chooser answer's files (`filechooser.respond`
    /// `files: [{ name, base64 }]`) from the budget: the driver stages them
    /// on disk for the page until the session ends.
    /// Each answer is one call (at most `perCall`, as a `writeFile`), each
    /// file one entry change, and the decoded bytes count toward the
    /// session's total. A cancel stages nothing.
    func takeFileChooserAnswer(_ params: [String: Any]) throws {
        guard params["cancel"] as? Bool != true, let files = params["files"] as? [[String: Any]], !files.isEmpty else { return }
        // Decoded size from the Base64 length, without decoding.
        let bytes = files.reduce(0) { total, file in
            let raw = (file["base64"] as? String ?? "").utf8
            let padding = raw.reversed().prefix(2).filter { $0 == UInt8(ascii: "=") }.count
            return total + max(0, raw.count / 4 * 3 - padding)
        }
        let display = "file chooser \(params["chooserId"] as? String ?? "")"
        try checkCall(bytes, syscall: "write", display: display)
        for _ in files { try takeEntryChange(syscall: "write", display: display) }
        try take(bytes, syscall: "write", display: display)
    }

    /// Throws `EFBIG` when one call of `count` bytes is past `perCall`.
    func checkCall(_ count: Int, syscall: String, display: String) throws {
        guard count <= perCall else {
            let refusal = BrowserReplResourceLimitError(resource: .fileBytesWritten, limit: perCall, isPerItem: true, held: ledger.held(.fileBytesWritten), requested: count)
            throw BrowserReplFileSystemError(code: "EFBIG", message: "EFBIG: file too large, \(syscall) '\(display)': \(refusal.message)")
        }
    }
}

/// An open file descriptor, closed when the last reference goes.
final class BrowserReplDescriptor: @unchecked Sendable {
    let fd: Int32

    init(_ fd: Int32) {
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    /// Where the open file or directory is now (it may have been renamed
    /// since it was opened), or nil when the system cannot tell.
    var currentPath: String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// The directories of an fs's roots, each opened once and held: every
/// operation walks from the held directory, never from the root's path
/// again. Shared by the copies of one `BrowserReplFileSystem`.
final class BrowserReplRootDirectories: @unchecked Sendable {
    private let lock = NSLock()
    /// Per root: its canonical path and its directory once opened.
    private var roots: [(path: String, directory: BrowserReplDescriptor?)]

    /// Holds the roots that are given open, and opens the others that exist.
    init(_ roots: [(path: String, directory: BrowserReplDescriptor?)]) {
        self.roots = roots.map { root in
            if root.directory != nil { return root }
            let descriptor = Self.open(root.path)
            return (root.path, descriptor >= 0 ? BrowserReplDescriptor(descriptor) : nil)
        }
    }

    /// Opens the directory at `path` (absolute and canonical: no link on
    /// the way when it was resolved) by a walk from `/`, one component at a
    /// time with `openat` and `O_NOFOLLOW`, so a link put in place of any
    /// component since then is never followed. With `creating`, missing
    /// directories are made on the way (`mkdirat`).
    /// - Returns: The descriptor, or -1 with `errno` set: `ELOOP` when a
    ///   component is a link.
    static func open(_ path: String, creating: Bool = false) -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { return -1 }
        for component in path.split(separator: "/").map(String.init) {
            var next = openat(current, component, flags)
            if next < 0, errno == ENOENT, creating {
                if mkdirat(current, component, 0o777) != 0, errno != EEXIST {
                    let number = errno
                    close(current)
                    errno = number
                    return -1
                }
                next = openat(current, component, flags)
            }
            guard next >= 0 else {
                var number = errno
                var info = stat()
                if fstatat(current, component, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                    number = ELOOP
                }
                close(current)
                errno = number
                return -1
            }
            close(current)
            current = next
        }
        return current
    }

    /// Root `index`'s held directory, when one is held for `path`.
    func descriptor(at index: Int, for path: String) -> BrowserReplDescriptor? {
        lock.withLock {
            guard roots.indices.contains(index), roots[index].path == path else { return nil }
            return roots[index].directory
        }
    }

    /// Holds `directory` for root `index` unless one is held already, and
    /// returns the held one.
    func hold(_ directory: BrowserReplDescriptor, at index: Int, for path: String) -> BrowserReplDescriptor {
        lock.withLock {
            guard roots.indices.contains(index), roots[index].path == path else { return directory }
            if let held = roots[index].directory { return held }
            roots[index].directory = directory
            return directory
        }
    }
}
