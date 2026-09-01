/// Stable device/inode identity for one filesystem entry authorized for reading.
public struct ChatArtifactFileIdentity: Sendable, Equatable, Hashable {
    /// Device number reported by `stat(2)`.
    public let device: UInt64
    /// Inode number reported by `stat(2)`.
    public let inode: UInt64

    /// Creates a filesystem identity value.
    ///
    /// - Parameters:
    ///   - device: Device number reported by `stat(2)`.
    ///   - inode: Inode number reported by `stat(2)`.
    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}
