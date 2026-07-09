public import CmuxSettings

/// The resolved control-socket listener configuration when the socket is enabled.
///
/// Produced by ``SocketListenerLifecycleCoordinator/configurationIfEnabled()`` by
/// reading ``SocketControlSettings``. A `nil` configuration means the socket is
/// disabled (mode ``SocketControlMode/off``) and the listener must not run.
public struct SocketListenerConfiguration: Equatable, Sendable {
    /// The effective access mode governing which clients may connect.
    public let mode: SocketControlMode
    /// The on-disk socket path the listener should bind.
    public let path: String

    /// Creates a resolved listener configuration.
    ///
    /// - Parameters:
    ///   - mode: The effective access mode.
    ///   - path: The socket path to bind.
    public init(mode: SocketControlMode, path: String) {
        self.mode = mode
        self.path = path
    }
}
