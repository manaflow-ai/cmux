/// The filesystem identity (device + inode) of a bound Unix-domain socket path.
///
/// Captured immediately after a successful `bind(2)` and compared against later
/// `lstat(2)` results to detect whether the path still refers to the socket this
/// process created, or has been removed/recreated by another process. Only the
/// owner of the current identity may unlink the path on shutdown.
public struct SocketPathIdentity: Equatable, Sendable {
    /// The `st_dev` of the socket inode.
    public let device: UInt64
    /// The `st_ino` of the socket inode.
    public let inode: UInt64

    /// Creates an identity from raw `stat(2)` fields.
    ///
    /// - Parameters:
    ///   - device: The `st_dev` value.
    ///   - inode: The `st_ino` value.
    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}
