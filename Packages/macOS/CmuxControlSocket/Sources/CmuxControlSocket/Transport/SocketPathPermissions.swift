internal import Darwin
internal import Foundation

enum SocketPathPermissions {
    static func apply(
        to path: String,
        matching identity: SocketPathIdentity?,
        permissions: mode_t,
        beforeMutation: () -> Void = {}
    ) -> Int32? {
        guard let identity else { return ESTALE }
        var current = stat()
        guard lstat(path, &current) == 0 else { return errno }
        guard current.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              UInt64(current.st_dev) == identity.device,
              UInt64(current.st_ino) == identity.inode else { return ESTALE }
        beforeMutation()
        guard chmod(path, permissions) == 0 else { return errno }
        return nil
    }
}
