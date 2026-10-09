/// Optional build identity fields reported by the Cloud daemon.
public struct CmxCloudDaemonBuild: Codable, Equatable, Sendable {
    /// Source revision, or nil when the daemon cannot report it.
    public let commit: String?
    /// Remote protocol version, or nil when unavailable.
    public let remoteProtocol: Int?
    /// Human-readable daemon version, or nil when unavailable.
    public let version: String?

    /// Creates a daemon identity; nil fields represent unavailable information.
    /// - Parameters:
    ///   - commit: Source revision.
    ///   - remoteProtocol: Remote protocol version.
    ///   - version: Human-readable daemon version.
    public init(commit: String?, remoteProtocol: Int?, version: String?) {
        self.commit = commit
        self.remoteProtocol = remoteProtocol
        self.version = version
    }
}
