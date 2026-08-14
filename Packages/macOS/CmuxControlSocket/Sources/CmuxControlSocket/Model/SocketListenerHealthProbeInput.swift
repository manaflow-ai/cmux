/// Sendable listener state captured before performing a socket-path probe.
///
/// The state mirror can be sampled on any caller, while the filesystem probe
/// can then run on a utility executor without carrying the main-actor server
/// reference across the concurrency boundary.
public struct SocketListenerHealthProbeInput: Sendable {
    /// Whether the listener reports itself as running.
    public let isRunning: Bool
    /// Whether the accept loop (or accept source) is alive.
    public let acceptLoopAlive: Bool
    /// The listener path captured in the state mirror.
    public let listenerSocketPath: String
    /// The path the caller expects the listener to own.
    public let expectedSocketPath: String
    /// The socket identity captured when the listener bound its path.
    public let boundSocketPathIdentity: SocketPathIdentity?

    /// Creates a probe input from listener state values.
    public init(
        isRunning: Bool,
        acceptLoopAlive: Bool,
        listenerSocketPath: String,
        expectedSocketPath: String,
        boundSocketPathIdentity: SocketPathIdentity?
    ) {
        self.isRunning = isRunning
        self.acceptLoopAlive = acceptLoopAlive
        self.listenerSocketPath = listenerSocketPath
        self.expectedSocketPath = expectedSocketPath
        self.boundSocketPathIdentity = boundSocketPathIdentity
    }

    /// Resolves the captured state and current filesystem identity into health.
    ///
    /// - Parameter transport: Stateless socket transport used for `lstat(2)`.
    /// - Returns: A point-in-time listener health value.
    public func resolve(using transport: SocketTransport) -> SocketListenerHealth {
        let pathMatches = listenerSocketPath == expectedSocketPath
        let currentIdentity = transport.pathIdentity(at: expectedSocketPath)
        let pathExists = currentIdentity != nil
        let pathOwnedByListener = currentIdentity.map { current in
            pathMatches && (boundSocketPathIdentity.map { current == $0 } ?? false)
        } ?? false

        return SocketListenerHealth(
            isRunning: isRunning,
            acceptLoopAlive: acceptLoopAlive,
            socketPathMatches: pathMatches,
            socketPathExists: pathExists,
            socketPathOwnedByListener: pathOwnedByListener
        )
    }
}
