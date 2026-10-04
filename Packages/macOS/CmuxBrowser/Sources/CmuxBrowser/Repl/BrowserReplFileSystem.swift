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
/// Files are opened with `O_NONBLOCK` and checked with `fstat` before any
/// read or write: a FIFO, socket or device fails with `EINVAL` at once
/// instead of waiting for its other end, and `readFile` refuses a file over
/// `maxReadFileBytes`. One `writeFile` (also an append) or `copyFile` writes
/// at most ``BrowserReplWriteBudget/maximumBytesPerCall`` and a session at
/// most ``BrowserReplWriteBudget/maximumBytesPerSession`` in all, each
/// refused before anything is written, and they write in chunks that stop
/// when the session cancels the call (its cell timed out or the session
/// closed). No lock is held across operations or sessions: the
/// descriptor walk is what keeps two sessions on one root, or a session and
/// another process, from racing each other's checks, so a slow operation
/// holds only its own session's thread.
public struct BrowserReplFileSystem: Sendable {
    /// The largest file `readFile` reads, 64 MiB (the fetch body limit).
    public static let maxReadFileBytes = 64 << 20

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
        do {
            return .success(try run(operation, arguments))
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

    private func run(_ operation: String, _ arguments: [String: Any]) throws -> Any {
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
            let (file, size) = try openFile(try locate(.read), display: display)
            guard size <= Self.maxReadFileBytes else { throw Self.fileTooLarge(size) }
            return try readAll(file, display: display).base64EncodedString()
        case "writeFile":
            let display = try raw("path")
            let data = Data(base64Encoded: arguments["base64"] as? String ?? "") ?? Data()
            let location = try locate(.write)
            guard let name = location.name else { throw Self.isDirectoryError }
            let append = arguments["append"] as? Bool == true
            // Refused before the file is opened, so an existing file is kept.
            try writeBudget.takeEntryChange(syscall: "write", display: display)
            try writeBudget.take(data.count, syscall: "write", display: display)
            // Truncated only once it is known to be a regular file.
            let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY | (append ? O_APPEND : 0)
            let descriptor = openat(location.directory.fd, name, flags, 0o666)
            guard descriptor >= 0 else {
                let number = errno
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
            if mkdirat(location.directory.fd, name, 0o777) != 0 {
                let number = errno
                if number == EEXIST, recursive, (try? location.status())?.isDirectory == true { return NSNull() }
                throw Self.posixError(number, syscall: "mkdir", display: display)
            }
            return NSNull()
        case "readdir":
            let display = try raw("path")
            let directory = try openDirectory(try locate(.read), display: display)
            return try Self.entries(of: directory).map { entry -> [String: Any] in
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
                    try Self.removeTree(in: location.directory, name: name, display: display)
                } else if unlinkat(location.directory.fd, name, AT_REMOVEDIR) != 0 {
                    throw Self.posixError(errno, syscall: "rm", display: display)
                }
            } else if unlinkat(location.directory.fd, name, 0) != 0 {
                // A link or file: remove the entry, never what a link points to.
                throw Self.posixError(errno, syscall: "rm", display: display)
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
            guard renameat(from.directory.fd, fromName, to.directory.fd, toName) == 0 else {
                throw Self.posixError(errno, syscall: "rename", display: "\(try raw("from"))' -> '\(try raw("to"))")
            }
            return NSNull()
        case "copyFile":
            let fromDisplay = try raw("from")
            let pair = "\(fromDisplay)' -> '\(try raw("to"))"
            let (source, size) = try openFile(try locate(.read, key: "from"), display: fromDisplay, syscall: "copyfile")
            let destination = try locate(.write, key: "to")
            guard let name = destination.name else { throw Self.isDirectoryError }
            try writeBudget.takeEntryChange(syscall: "copyfile", display: pair)
            try writeBudget.take(size, syscall: "copyfile", display: pair)
            // Copy next to the destination, then swap it in, so a failed copy
            // leaves an existing destination untouched.
            let staging = ".\(name).cmux-copy-\(UUID().uuidString)"
            let descriptor = openat(destination.directory.fd, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
            guard descriptor >= 0 else { throw Self.posixError(errno, syscall: "copyfile", display: pair) }
            let copy = BrowserReplDescriptor(descriptor)
            do {
                try copyData(from: source, to: copy, size: size, display: pair)
                // Mode, times and extended attributes, as fcopyfile's own copy.
                guard fcopyfile(source.fd, copy.fd, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR)) == 0,
                      renameat(destination.directory.fd, staging, destination.directory.fd, name) == 0 else {
                    throw Self.posixError(errno, syscall: "copyfile", display: pair)
                }
            } catch {
                unlinkat(destination.directory.fd, staging, 0)
                throw error
            }
            return NSNull()
        default:
            throw BrowserReplFileSystemError(code: "EINVAL", message: "EINVAL: unsupported fs operation '\(operation)'")
        }
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

        /// The entry's status, not following a link.
        func status(display: String = "", syscall: String = "stat") throws -> FileStatus {
            var info = stat()
            let result = name.map { fstatat(directory.fd, $0, &info, AT_SYMLINK_NOFOLLOW) } ?? fstat(directory.fd, &info)
            guard result == 0 else { throw BrowserReplFileSystem.posixError(errno, syscall: syscall, display: display) }
            return FileStatus(info)
        }
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
    /// directory in its place, changes nothing for this fs.
    private func openRoot(_ index: Int, creating: Bool) throws -> BrowserReplDescriptor {
        let root = roots[index]
        if let held = rootDirectories.descriptor(at: index, for: root) { return held }
        var descriptor = BrowserReplRootDirectories.open(root)
        if descriptor < 0, errno == ENOENT, creating {
            // The root itself is outside the sandbox's reach; only `mkdir -p`
            // creates a working directory that does not exist yet.
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            descriptor = BrowserReplRootDirectories.open(root)
        }
        guard descriptor >= 0 else { throw Self.posixError(errno, syscall: "open", display: root) }
        return rootDirectories.hold(BrowserReplDescriptor(descriptor), at: index, for: root)
    }

    /// Whether `location` is a root, or an entry that is one (reached
    /// through another root or a link to it).
    private func isRoot(_ location: Location) -> Bool {
        guard location.name != nil else { return true }
        guard let entry = try? location.status() else { return false }
        return roots.indices.contains { index in
            guard let root = try? openRoot(index, creating: false),
                  let status = try? Location(directory: root, name: nil).status() else { return false }
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
                return Location(directory: directory, name: component)
            }
            var info = stat()
            if fstatat(directory.fd, component, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                let number = errno
                guard number == ENOENT else { throw Self.posixError(number, syscall: "open", display: display) }
                if isLast { return Location(directory: directory, name: component) }
                guard creatingDirectories else { throw Self.posixError(ENOENT, syscall: "open", display: display) }
                try writeBudget.takeEntryChange(syscall: "mkdir", display: display)
                if mkdirat(directory.fd, component, 0o777) != 0, errno != EEXIST {
                    throw Self.posixError(errno, syscall: "mkdir", display: display)
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
                    pending.append(contentsOf: below.reversed())
                } else {
                    pending.append(contentsOf: target.split(separator: "/", omittingEmptySubsequences: true).map(String.init).reversed())
                }
                continue
            }
            if isLast { return Location(directory: directory, name: component) }
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
        guard let last = names.popLast() else { return Location(directory: directory, name: nil) }
        try reopen()
        return Location(directory: directory, name: last)
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
        return Location(directory: directory, name: name)
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
    private func openFile(_ location: Location, display: String, syscall: String = "open") throws -> (BrowserReplDescriptor, Int) {
        guard let name = location.name else { throw Self.isDirectoryError }
        let descriptor = openat(location.directory.fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | O_NOCTTY)
        guard descriptor >= 0 else {
            let number = errno
            if number == ENXIO || number == EOPNOTSUPP { throw Self.notRegularFile(display, syscall: syscall) }
            throw Self.posixError(number, syscall: syscall, display: display)
        }
        let file = BrowserReplDescriptor(descriptor)
        return (file, try Self.requireRegularFile(file, display: display, syscall: syscall))
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

    /// Reads the file to its end; past `maxReadFileBytes` (a file that grew
    /// after its size was checked) it fails.
    private func readAll(_ file: BrowserReplDescriptor, display: String) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
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

    private static func cancelledError(syscall: String, display: String) -> BrowserReplFileSystemError {
        BrowserReplFileSystemError(
            code: "ECANCELED",
            message: "ECANCELED: operation canceled because its cell timed out or the session ended, \(syscall) '\(display)'"
        )
    }

    /// Opens the directory at `location` for listing.
    private func openDirectory(_ location: Location, display: String) throws -> BrowserReplDescriptor {
        guard let name = location.name else {
            let copy = dup(location.directory.fd)
            guard copy >= 0 else { throw Self.posixError(errno, syscall: "scandir", display: display) }
            return BrowserReplDescriptor(copy)
        }
        let descriptor = openat(location.directory.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError(errno, syscall: "scandir", display: display) }
        return BrowserReplDescriptor(descriptor)
    }

    /// The entries of an open directory, by name, with their types (a link
    /// is a `symlink`).
    static func entries(of directory: BrowserReplDescriptor) throws -> [(name: String, type: String)] {
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
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let type: String
            switch Int32(entry.pointee.d_type) {
            case DT_REG: type = "file"
            case DT_DIR: type = "directory"
            case DT_LNK: type = "symlink"
            case DT_UNKNOWN:
                type = (try? Location(directory: directory, name: name).status().type) ?? "other"
            default: type = "other"
            }
            result.append((name, type))
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Removes directory `name` in `parent` and everything in it, following
    /// no link. Holds at most two directories open: it descends by name
    /// from `parent` with `O_NOFOLLOW` at each step, so a deep tree cannot
    /// use up descriptors.
    private static func removeTree(in parent: BrowserReplDescriptor, name: String, display: String) throws {
        func open(_ path: ArraySlice<String>) throws -> BrowserReplDescriptor {
            var current = parent
            for component in path {
                let next = openat(current.fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posixError(errno, syscall: "rm", display: display) }
                current = BrowserReplDescriptor(next)
            }
            return current
        }
        var path = [name]
        while let last = path.last {
            let directory = try open(path[...])
            var subdirectory: String?
            for entry in try entries(of: directory) {
                if entry.type == "directory" {
                    subdirectory = subdirectory ?? entry.name
                } else if unlinkat(directory.fd, entry.name, 0) != 0, errno != ENOENT {
                    throw posixError(errno, syscall: "rm", display: display)
                }
            }
            if let subdirectory {
                path.append(subdirectory)
                continue
            }
            let holder = try open(path.dropLast())
            if unlinkat(holder.fd, last, AT_REMOVEDIR) != 0, errno != ENOENT {
                throw posixError(errno, syscall: "rm", display: display)
            }
            path.removeLast()
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
/// and `perSessionEntryChanges` changes to entries (a file written or
/// copied, also an empty one, a directory made, an entry renamed or
/// removed), so agent code can fill neither the disk nor its entries.
/// Shared by the fs copies of one session.
final class BrowserReplWriteBudget: @unchecked Sendable {
    /// The most one `writeFile` (also an append) or `copyFile` writes, 256 MiB.
    static let maximumBytesPerCall = 256 << 20
    /// The most a session's fs writes over its life, 2 GiB.
    static let maximumBytesPerSession = 2 << 30
    /// The most entry changes a session's fs makes over its life.
    static let maximumEntryChangesPerSession = 100_000

    let perCall: Int
    let perSession: Int
    let perSessionEntryChanges: Int
    private let lock = NSLock()
    private var written = 0
    private var entryChanges = 0

    init(
        perCall: Int = BrowserReplWriteBudget.maximumBytesPerCall,
        perSession: Int = BrowserReplWriteBudget.maximumBytesPerSession,
        perSessionEntryChanges: Int = BrowserReplWriteBudget.maximumEntryChangesPerSession
    ) {
        self.perCall = perCall
        self.perSession = perSession
        self.perSessionEntryChanges = perSessionEntryChanges
    }

    /// Takes one entry change (a file written or copied, a directory made,
    /// an entry renamed or removed) from the budget, or throws `EDQUOT`
    /// when the session made its limit of them.
    func takeEntryChange(syscall: String, display: String) throws {
        let taken: Bool = lock.withLock {
            guard entryChanges < perSessionEntryChanges else { return false }
            entryChanges += 1
            return true
        }
        guard taken else {
            throw BrowserReplFileSystemError(
                code: "EDQUOT",
                message: "EDQUOT: the REPL session has made its limit of \(perSessionEntryChanges) file changes (files written, directories made, entries renamed or removed), \(syscall) '\(display)'; reset the session (cmux browser repl reset NAME) to make more"
            )
        }
    }

    /// Takes `count` bytes from the budget, or throws `EFBIG` when the call
    /// (`callBytes` in all, `count` by default) is past `perCall`, or
    /// `EDQUOT` when the session's budget is used up.
    func take(_ count: Int, syscall: String, display: String, callBytes: Int? = nil) throws {
        try checkCall(callBytes ?? count, syscall: syscall, display: display)
        let taken: Bool = lock.withLock {
            guard written + count <= perSession else { return false }
            written += count
            return true
        }
        guard taken else {
            throw BrowserReplFileSystemError(
                code: "EDQUOT",
                message: "EDQUOT: the REPL session has written its limit of \(Self.describe(perSession)) of files, \(syscall) '\(display)'; reset the session (cmux browser repl reset NAME) to write more"
            )
        }
    }

    /// Throws `EFBIG` when one call of `count` bytes is past `perCall`.
    func checkCall(_ count: Int, syscall: String, display: String) throws {
        guard count <= perCall else {
            throw BrowserReplFileSystemError(
                code: "EFBIG",
                message: "EFBIG: file too large, \(syscall) '\(display)': fs writes at most \(Self.describe(perCall)) in one call (this one is \(count) bytes)"
            )
        }
    }

    /// `256 MiB`, `2 GiB` or `1000 bytes`.
    private static func describe(_ bytes: Int) -> String {
        if bytes >= 1 << 30, bytes % (1 << 30) == 0 { return "\(bytes >> 30) GiB" }
        if bytes >= 1 << 20, bytes % (1 << 20) == 0 { return "\(bytes >> 20) MiB" }
        return "\(bytes) bytes"
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

    /// Opens the directory at `path` (canonical: no link on the way), not
    /// following a link in its place.
    static func open(_ path: String) -> Int32 {
        Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
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
