#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Filesystem identity of a local Unix-domain socket endpoint.
///
/// Captured via `lstat` before connect and rechecked after connect to reduce
/// path-swap races. A socket path string alone is never treated as identity.
public struct NestedUnixSocketFileIdentity: Hashable, Codable, Sendable {
    /// Device ID from `stat.st_dev`.
    public let deviceID: UInt64
    /// Inode from `stat.st_ino`.
    public let inode: UInt64

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case inode
    }

    /// Creates a socket file identity.
    public init(deviceID: UInt64, inode: UInt64) {
        self.deviceID = deviceID
        self.inode = inode
    }

    /// Creates an identity from a POSIX `stat` buffer.
    init(statBuffer: stat) {
        self.deviceID = UInt64(statBuffer.st_dev)
        self.inode = UInt64(statBuffer.st_ino)
    }
}
