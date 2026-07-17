/// Metadata returned by the daemon's capability-gated `fs.stat` RPC.
public struct RemoteDaemonFileStat: Equatable, Sendable {
    /// Filesystem object kinds represented on the RPC wire.
    public enum Kind: String, Equatable, Sendable {
        /// A regular file.
        case file
        /// A directory.
        case directory
        /// Any filesystem object that is neither a regular file nor directory.
        case other
    }

    /// Whether the requested path exists.
    public let exists: Bool
    /// The object's kind, or `nil` when ``exists`` is false.
    public let kind: Kind?
    /// The object's byte size, or `nil` when ``exists`` is false.
    public let size: Int64?

    /// Creates a filesystem metadata snapshot.
    ///
    /// - Parameters:
    ///   - exists: Whether the requested path exists.
    ///   - kind: The object's kind when it exists.
    ///   - size: The object's byte size when it exists.
    public init(exists: Bool, kind: Kind?, size: Int64?) {
        self.exists = exists
        self.kind = kind
        self.size = size
    }
}
