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
/// an open descriptor of its root, one entry at a time, with `openat` and
/// `O_NOFOLLOW`, and acts on the entry relative to the directory it holds
/// open (`openat`, `fstatat`, `mkdirat`, `unlinkat`, `renameat`). A link on
/// the way is read with `readlinkat` and followed only while it stays inside
/// a root, so neither another session nor another local process can swap a
/// link in for a directory between the check and the use: the directory
/// already open is the one acted on.
public struct BrowserReplFileSystem: Sendable {
    /// The sandbox that authorizes every path.
    public var sandbox: BrowserReplFileSandbox

    /// The session's own canonical temporary directory, a second root next
    /// to the sandbox root, or `nil` for none.
    public let temporaryRoot: String?

    /// - Parameter temporaryDirectory: The session's private temporary
    ///   directory (`os.tmpdir()` in the REPL), never a directory other
    ///   sessions or apps share; `nil` gives the sandbox root only.
    public init(sandbox: BrowserReplFileSandbox, temporaryDirectory: String? = nil) {
        self.sandbox = sandbox
        self.temporaryRoot = temporaryDirectory.map {
            BrowserReplFileSandbox.canonicalize(BrowserReplFileSandbox.lexicallyNormalized($0))
        }
    }

    /// Runs one operation. See `docs/browser-repl/driver-protocol.md` for ops.
    public func perform(_ operation: String, arguments: [String: Any]) -> Result<Any, BrowserReplFileSystemError> {
        Self.operationLock.lock()
        defer { Self.operationLock.unlock() }
        do {
            return .success(try run(operation, arguments))
        } catch let error as BrowserReplFileSystemError {
            return .failure(error)
        } catch {
            return .failure(Self.translate(error, operation: operation, path: arguments["path"] as? String ?? ""))
        }
    }

    /// Held for each operation.
    private static let operationLock = NSLock()

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
            let file = try openFile(try locate(.read), display: display)
            return try readAll(file, display: display).base64EncodedString()
        case "writeFile":
            let display = try raw("path")
            let data = Data(base64Encoded: arguments["base64"] as? String ?? "") ?? Data()
            let location = try locate(.write)
            guard let name = location.name else { throw Self.isDirectoryError }
            let append = arguments["append"] as? Bool == true
            let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (append ? O_APPEND : O_TRUNC)
            let descriptor = openat(location.directory.fd, name, flags, 0o666)
            guard descriptor >= 0 else { throw Self.posixError(errno, syscall: "open", display: display) }
            let file = BrowserReplDescriptor(descriptor)
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
            guard renameat(from.directory.fd, fromName, to.directory.fd, toName) == 0 else {
                throw Self.posixError(errno, syscall: "rename", display: "\(try raw("from"))' -> '\(try raw("to"))")
            }
            return NSNull()
        case "copyFile":
            let fromDisplay = try raw("from")
            let pair = "\(fromDisplay)' -> '\(try raw("to"))"
            let source = try openFile(try locate(.read, key: "from"), display: fromDisplay, syscall: "copyfile")
            let destination = try locate(.write, key: "to")
            guard let name = destination.name else { throw Self.isDirectoryError }
            // Copy next to the destination, then swap it in, so a failed copy
            // leaves an existing destination untouched.
            let staging = ".\(name).cmux-copy-\(UUID().uuidString)"
            let descriptor = openat(destination.directory.fd, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
            guard descriptor >= 0 else { throw Self.posixError(errno, syscall: "copyfile", display: pair) }
            let copy = BrowserReplDescriptor(descriptor)
            guard fcopyfile(source.fd, copy.fd, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_STAT | COPYFILE_XATTR)) == 0,
                  renameat(destination.directory.fd, staging, destination.directory.fd, name) == 0 else {
                let number = errno
                unlinkat(destination.directory.fd, staging, 0)
                throw Self.posixError(number, syscall: "copyfile", display: pair)
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

    private func openRoot(_ index: Int, creating: Bool) throws -> BrowserReplDescriptor {
        let root = roots[index]
        var descriptor = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT, creating {
            // The root itself is outside the sandbox's reach; only `mkdir -p`
            // creates a working directory that does not exist yet.
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            descriptor = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw Self.posixError(errno, syscall: "open", display: root) }
        return BrowserReplDescriptor(descriptor)
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

    /// Opens the file at `location` for reading; a directory fails with `EISDIR`.
    private func openFile(_ location: Location, display: String, syscall: String = "open") throws -> BrowserReplDescriptor {
        guard let name = location.name else { throw Self.isDirectoryError }
        let descriptor = openat(location.directory.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError(errno, syscall: syscall, display: display) }
        let file = BrowserReplDescriptor(descriptor)
        var info = stat()
        guard fstat(file.fd, &info) == 0 else { throw Self.posixError(errno, syscall: syscall, display: display) }
        if (info.st_mode & S_IFMT) == S_IFDIR { throw Self.isDirectoryError }
        return file
    }

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
            data.append(buffer, count: count)
        }
    }

    private func writeAll(_ data: Data, to file: BrowserReplDescriptor, display: String) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                let count = write(file.fd, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError(errno, syscall: "write", display: display)
                }
                offset += count
            }
        }
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

/// An open file descriptor, closed when the last reference goes.
final class BrowserReplDescriptor {
    let fd: Int32

    init(_ fd: Int32) {
        self.fd = fd
    }

    deinit {
        close(fd)
    }
}
