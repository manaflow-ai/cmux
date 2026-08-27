import Darwin
import Foundation

/// Stable device/inode identity for one ordinary filesystem entry.
public struct ArtifactFileIdentity: Sendable, Equatable, Hashable {
    /// Device number reported by `stat(2)`.
    public let device: UInt64
    /// Inode number reported by `stat(2)`.
    public let inode: UInt64

    /// Creates a filesystem identity value.
    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    /// Reads the identity of one regular file without following a final link.
    ///
    /// - Parameter url: File URL to inspect.
    /// - Returns: The opened file's device/inode pair.
    /// - Throws: ``ArtifactStoreError/pathOutsideStore(_:)`` when the entry
    ///   cannot be inspected as a regular file.
    static func read(at url: URL) throws -> Self {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            throw ArtifactStoreError.pathOutsideStore(url.path)
        }
        return Self(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }
}
