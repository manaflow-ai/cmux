internal import Darwin
public import Network

/// A Unix socket path that does not fit a socket address (`sun_path`): nothing can listen there,
/// and `NWEndpoint.unix(path:)` traps on it.
public struct UnixSocketPathTooLong: Error, Equatable, Sendable {
    /// The refused path.
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

public extension NWEndpoint {
    /// The longest Unix socket path in bytes: `sun_path` less its terminating NUL (103 on macOS).
    static let unixSocketPathLimit = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// `.unix(path:)` for a path that fits a Unix socket address, else ``UnixSocketPathTooLong``.
    /// The Network framework traps on a longer path, so a long TMPDIR or home folder crashed the
    /// whole process (issue #28492); every `NWConnection` to a Unix socket goes through this.
    static func unixSocket(path: String) throws(UnixSocketPathTooLong) -> NWEndpoint {
        guard path.utf8.count <= unixSocketPathLimit else { throw UnixSocketPathTooLong(path: path) }
        return .unix(path: path)
    }
}
