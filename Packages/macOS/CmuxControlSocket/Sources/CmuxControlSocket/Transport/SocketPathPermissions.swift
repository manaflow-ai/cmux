internal import Darwin
internal import Foundation

/// Pins a socket inode before changing its mode. Darwin rejects fchmod on a
/// listening socket descriptor; chmod on the public path can hit a replacement.
enum SocketPathPermissions {
    static func apply(
        to path: String,
        matching identity: SocketPathIdentity?,
        permissions: mode_t,
        beforeMutation: () -> Void = {}
    ) -> Int32? {
        guard let identity else { return ESTALE }
        // Keep the anchor on the socket's filesystem. mkdtemp creates a private
        // 0700 directory, and relative operations use its pinned descriptor.
        let parent = (path as NSString).deletingLastPathComponent
        var template = Array((parent + "/.cmux-permissions-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { return errno }
        let directory = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        defer { _ = rmdir(directory) }
        let directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return errno }
        defer { close(directoryFD) }

        guard linkat(AT_FDCWD, path, directoryFD, "socket", 0) == 0 else { return errno }
        defer { _ = unlinkat(directoryFD, "socket", 0) }
        var pinned = stat()
        guard fstatat(directoryFD, "socket", &pinned, AT_SYMLINK_NOFOLLOW) == 0 else { return errno }
        guard pinned.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              UInt64(pinned.st_dev) == identity.device,
              UInt64(pinned.st_ino) == identity.inode else { return ESTALE }

        beforeMutation()
        guard fchmodat(directoryFD, "socket", permissions, AT_SYMLINK_NOFOLLOW) == 0 else { return errno }
        // The mutation affected only the pinned inode. A replaced public path
        // still requires the host to stop/rebind instead of reporting success.
        var current = stat()
        guard lstat(path, &current) == 0 else { return errno }
        guard current.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              UInt64(current.st_dev) == identity.device,
              UInt64(current.st_ino) == identity.inode else { return ESTALE }
        return nil
    }
}
