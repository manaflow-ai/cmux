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

    private init(exists: Bool, kind: Kind?, size: Int64?) {
        self.exists = exists
        self.kind = kind
        self.size = size
    }

    /// Metadata for a path that does not exist.
    public static let missing = RemoteDaemonFileStat(exists: false, kind: nil, size: nil)

    /// Validated constructor used by the daemon wire decoder.
    static func existing(kind: Kind, size: Int64) -> RemoteDaemonFileStat {
        RemoteDaemonFileStat(exists: true, kind: kind, size: size)
    }
}
