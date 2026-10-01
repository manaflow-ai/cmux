import Foundation

/// The build identity observed from a live cmux-tui daemon.
///
/// This is deliberately optional at every call site. Older daemons and cached
/// carrier reconnects may not report an identity, so consumers must describe
/// the value as an observation rather than an expected or current release.
public struct SurfaceDaemonBuild: Hashable, Codable, Sendable {
    public var commit: String?
    public var remoteProtocol: Int?
    public var version: String?

    public init(commit: String? = nil, remoteProtocol: Int? = nil, version: String? = nil) {
        self.commit = commit
        self.remoteProtocol = remoteProtocol
        self.version = version
    }

    public var displayName: String {
        if let version, !version.isEmpty { return version }
        if let commit, !commit.isEmpty { return String(commit.prefix(12)) }
        return String(localized: "cloudTree.daemonBuild.unknown", defaultValue: "unknown")
    }
}
