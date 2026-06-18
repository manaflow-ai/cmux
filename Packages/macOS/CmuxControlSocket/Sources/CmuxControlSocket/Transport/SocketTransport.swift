public import Foundation
internal import Darwin

/// The syscall layer for the cmux control socket: path identity and liveness
/// probing, advisory lock-file arbitration, listener binding, accepted-client
/// configuration, and raw socket I/O.
///
/// Stateless; every operation acts on the paths and descriptors it is given.
/// Construct once at the composition root and inject. The timeouts and lock
/// vocabulary are configurable for tests:
///
/// ```swift
/// let transport = SocketTransport()
/// switch transport.bindListenerSocket(fd, path: path, canReplaceRefusedSocket: false) {
/// case .success(let path, let identity): ...
/// case .pathTooLong(let path): ...
/// case .failure(let path, let stage, let errnoCode): ...
/// }
/// ```
public struct SocketTransport: Sendable {
    /// Receive timeout applied to accepted client sockets.
    public let clientReadTimeout: TimeInterval
    /// Send timeout applied to accepted client sockets.
    public let clientWriteTimeout: TimeInterval
    /// Backlog passed to `listen(2)`.
    public let listenBacklog: Int32
    /// Suffix appended to a socket path to form its advisory lock-file path.
    public let pathLockSuffix: String
    /// Marker content a lock file carries once its socket path is known to be
    /// reclaimable by a future listener.
    public let pathLockReusableMarker: String

    /// The longest path that fits in `sockaddr_un.sun_path` (one byte reserved
    /// for the null terminator).
    public static let unixSocketPathMaxLength: Int = {
        var addr = sockaddr_un()
        // Reserve one byte for the null terminator.
        return MemoryLayout.size(ofValue: addr.sun_path) - 1
    }()

    /// Creates a transport.
    ///
    /// - Parameters:
    ///   - clientReadTimeout: Receive timeout for accepted clients (default 30s).
    ///   - clientWriteTimeout: Send timeout for accepted clients (default 5s).
    ///   - listenBacklog: `listen(2)` backlog (default 128).
    ///   - pathLockSuffix: Lock-file suffix (default `".lock"`).
    ///   - pathLockReusableMarker: Reusable-lock marker content (default
    ///     `"cmux-socket-lock-v1\n"`).
    public init(
        clientReadTimeout: TimeInterval = 30,
        clientWriteTimeout: TimeInterval = 5,
        listenBacklog: Int32 = 128,
        pathLockSuffix: String = ".lock",
        pathLockReusableMarker: String = "cmux-socket-lock-v1\n"
    ) {
        self.clientReadTimeout = clientReadTimeout
        self.clientWriteTimeout = clientWriteTimeout
        self.listenBacklog = listenBacklog
        self.pathLockSuffix = pathLockSuffix
        self.pathLockReusableMarker = pathLockReusableMarker
    }

    /// Builds a `sockaddr_un` for `path`, or nil when the path does not fit.
    func unixSocketAddress(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLength = Self.unixSocketPathMaxLength + 1
        var didFit = false
        path.withCString { source in
            let sourceLength = strlen(source)
            guard sourceLength < maxLength else { return }

            _ = withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
            }
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let destination = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(destination, source, maxLength - 1)
            }
            didFit = true
        }
        return didFit ? addr : nil
    }
}
