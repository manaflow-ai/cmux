package import Darwin
package import Foundation

/// Descriptor-relative private storage for `downloads.json`.
///
/// The app owns the final directory and file names. The directory and every opened file reject
/// symlinks, require this user as owner, have extended ACLs removed, and receive private POSIX
/// modes through their descriptors. Writes prepare a private same-directory file and publish it
/// with `renameat`, so a path swap cannot redirect chmod or content outside this directory.
package nonisolated struct BrowserDownloadHistoryStorage: BrowserDownloadHistoryStoring {
    package let url: URL

    package init(url: URL) { self.url = url }

    private var directory: URL { url.deletingLastPathComponent() }
    private var filename: String { url.lastPathComponent }

    package func read() throws -> Data? {
        let directoryDescriptor = try openDirectory(create: true)
        defer { Darwin.close(directoryDescriptor) }
        let descriptor = filename.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Self.error()
        }
        defer { Darwin.close(descriptor) }
        try Self.secure(descriptor, mode: 0o600, kind: S_IFREG)
        // concurrency-allow: the App history model calls this repository only from its detached I/O task.
        return try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd()
    }

    package func write(_ data: Data) throws {
        let directoryDescriptor = try openDirectory(create: true)
        defer { Darwin.close(directoryDescriptor) }
        let temporary = ".\(filename).\(UUID().uuidString).tmp"
        var descriptor = temporary.withCString {
            openat(directoryDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw Self.error() }
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            temporary.withCString { _ = unlinkat(directoryDescriptor, $0, 0) }
        }

        try Self.secure(descriptor, mode: 0o600, kind: S_IFREG)
        try Self.write(data, to: descriptor)
        guard fsync(descriptor) == 0 else { throw Self.error() }
        guard Darwin.close(descriptor) == 0 else { throw Self.error() }
        descriptor = -1
        let renamed = temporary.withCString { source in
            filename.withCString { destination in
                renameat(directoryDescriptor, source, directoryDescriptor, destination)
            }
        }
        guard renamed == 0 else { throw Self.error() }
    }

    package func remove() throws {
        guard let directoryDescriptor = try optionalDirectory() else { return }
        defer { Darwin.close(directoryDescriptor) }
        let result = filename.withCString { unlinkat(directoryDescriptor, $0, 0) }
        if result != 0, errno != ENOENT { throw Self.error() }
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        if let descriptor = try optionalDirectory() { return descriptor }
        guard create else { throw POSIXError(.ENOENT) }
        let parent = directory.deletingLastPathComponent()
        let name = try Self.component(directory.lastPathComponent)
        let parentDescriptor = parent.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard parentDescriptor >= 0 else { throw Self.error() }
        defer { Darwin.close(parentDescriptor) }
        let made = name.withCString { mkdirat(parentDescriptor, $0, 0o700) }
        if made != 0, errno != EEXIST { throw Self.error() }
        let descriptor = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw Self.error() }
        do {
            try Self.secure(descriptor, mode: 0o700, kind: S_IFDIR)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func optionalDirectory() throws -> Int32? {
        _ = try Self.component(filename)
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Self.error()
        }
        do {
            try Self.secure(descriptor, mode: 0o700, kind: S_IFDIR)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func secure(_ descriptor: Int32, mode: mode_t, kind: mode_t) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw error() }
        guard information.st_uid == geteuid(), information.st_mode & S_IFMT == kind else {
            throw POSIXError(.EPERM)
        }
        guard let emptyACL = acl_init(0) else { throw error() }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        guard acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED) == 0 else { throw error() }
        guard fchmod(descriptor, mode) == 0 else { throw error() }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw error()
                }
                offset += count
            }
        }
    }

    private static func component(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/") else {
            throw POSIXError(.EINVAL)
        }
        return value
    }

    private static func error() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
