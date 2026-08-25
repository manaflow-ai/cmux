import Darwin
import Foundation

/// Captures the filesystem identity of a working directory at approval time.
struct SudoDirectoryIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(path: String) throws {
        var status = stat()
        guard path.withCString({ stat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            throw SudoDirectoryIdentityError.unavailable
        }
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
    }

    func matches(path: String) -> Bool {
        (try? SudoDirectoryIdentity(path: path)) == self
    }
}

private enum SudoDirectoryIdentityError: Error {
    case unavailable
}
