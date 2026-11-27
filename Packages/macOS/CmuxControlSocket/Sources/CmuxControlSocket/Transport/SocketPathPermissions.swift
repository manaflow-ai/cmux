internal import Darwin
internal import Foundation

/// Owns a private link to a validated socket inode for the lifetime of a
/// permission update. Darwin rejects fchmod on the listening descriptor.
final class SocketPathPermissions {
    private let path: String
    private let identity: SocketPathIdentity
    private let directory: String
    private let directoryFD: Int32

    init(path: String, matching identity: SocketPathIdentity?) throws {
        guard let identity else { throw POSIXError(.ESTALE) }
        let parent = (path as NSString).deletingLastPathComponent
        let anchorParent = parent.isEmpty ? "." : parent
        var template = Array((anchorParent + "/.cmux-permissions-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let directory = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var ownsAnchor = false
        defer { if !ownsAnchor { _ = rmdir(directory) } }
        let directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            if !ownsAnchor {
                _ = unlinkat(directoryFD, "socket", 0)
                close(directoryFD)
            }
        }
        // The private directory stays on the socket's filesystem. Its pinned
        // descriptor keeps the anchor stable even if its parent is renamed.
        guard linkat(AT_FDCWD, path, directoryFD, "socket", 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var pinned = stat()
        guard fstatat(directoryFD, "socket", &pinned, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard pinned.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              UInt64(pinned.st_dev) == identity.device,
              UInt64(pinned.st_ino) == identity.inode else { throw POSIXError(.ESTALE) }

        self.path = path
        self.identity = identity
        self.directory = directory
        self.directoryFD = directoryFD
        ownsAnchor = true
    }

    deinit {
        _ = unlinkat(directoryFD, "socket", 0)
        close(directoryFD)
        _ = rmdir(directory)
    }

    func apply(permissions: mode_t) -> Int32? {
        guard fchmodat(directoryFD, "socket", permissions, AT_SYMLINK_NOFOLLOW) == 0 else { return errno }
        // Only the pinned inode was mutated. A replaced public path still
        // requires the host to stop/rebind instead of reporting success.
        var current = stat()
        guard lstat(path, &current) == 0 else { return errno }
        guard current.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              UInt64(current.st_dev) == identity.device,
              UInt64(current.st_ino) == identity.inode else { return ESTALE }
        return nil
    }
}
