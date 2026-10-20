import Darwin
package import Foundation

/// Writes a new private file without following or replacing its final path.
///
/// The caller chooses an existing parent directory. The writer opens that directory once, then
/// creates the final component relative to its descriptor with `O_EXCL | O_NOFOLLOW`, so a path
/// swap cannot turn a new-file operation into replacement. A failed write removes only the inode
/// this call created; it never unlinks a replacement installed by another process.
package nonisolated struct ExclusiveFileWriter: Sendable {
    package init() {}

    /// Writes `data` to a new mode-0600 regular file at `url`.
    ///
    /// The parent directory must already exist. If any object already has the final name, this
    /// throws `EEXIST` and leaves that object unchanged.
    @concurrent package func write(_ data: Data, to url: URL) async throws {
        try writeSynchronously(data, to: url)
    }

    /// Copies `source` into a new mode-0600 regular file at `destination` off the caller's actor.
    @concurrent package func copy(from source: URL, to destination: URL) async throws {
        try writeSynchronously(Data(contentsOf: source, options: .mappedIfSafe), to: destination)
    }

    private func writeSynchronously(_ data: Data, to url: URL) throws {
        let filename = try component(url.lastPathComponent)
        let parent = url.deletingLastPathComponent().path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard parent >= 0 else { throw systemError() }
        defer { Darwin.close(parent) }

        let descriptor = filename.withCString {
            openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw systemError() }

        var created = stat()
        guard fstat(descriptor, &created) == 0 else {
            let failure = systemError()
            Darwin.close(descriptor)
            throw failure
        }
        var complete = false
        defer {
            if !complete { removeCreatedFile(filename, from: parent, matching: created) }
            Darwin.close(descriptor)
        }

        guard created.st_uid == geteuid(), created.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.EPERM)
        }
        if let emptyACL = acl_init(0) {
            defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
            guard acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED) == 0 else { throw systemError() }
        } else {
            throw systemError()
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw systemError() }
        try write(data, to: descriptor)
        guard fsync(descriptor) == 0 else { throw systemError() }
        complete = true
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }

    private func removeCreatedFile(_ filename: String, from parent: Int32, matching created: stat) {
        var current = stat()
        let isSameFile = filename.withCString {
            fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW) == 0
                && current.st_dev == created.st_dev && current.st_ino == created.st_ino
        }
        guard isSameFile else { return }
        filename.withCString { _ = unlinkat(parent, $0, 0) }
    }

    private func component(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/") else {
            throw POSIXError(.EINVAL)
        }
        return value
    }

    private func systemError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
