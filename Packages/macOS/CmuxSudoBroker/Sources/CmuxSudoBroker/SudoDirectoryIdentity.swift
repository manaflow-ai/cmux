import Darwin
import Foundation

/// Captures the filesystem identity of a working directory at approval time.
struct SudoDirectoryIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    init(path: String) throws {
        var status = stat()
        guard path.withCString({ stat($0, &status) }) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            throw SudoDirectoryIdentityError.unavailable
        }
        self.init(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    func matches(path: String) -> Bool {
        (try? SudoDirectoryIdentity(path: path)) == self
    }
}

private enum SudoDirectoryIdentityError: Error {
    case unavailable
}
