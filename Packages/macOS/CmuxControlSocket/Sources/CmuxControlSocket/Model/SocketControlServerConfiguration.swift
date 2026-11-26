public import CmuxSettings

/// The complete resolved configuration that determines control-socket runtime behavior.
public struct SocketControlServerConfiguration: Equatable, Sendable {
    /// The access policy enforced for new and existing client commands.
    public let accessMode: SocketControlMode

    /// The preferred Unix-domain socket path used when a listener must start.
    public let preferredSocketPath: String

    /// Creates a control-socket configuration snapshot.
    /// - Parameters:
    ///   - accessMode: The access policy to enforce.
    ///   - preferredSocketPath: The listener path to use when the server starts.
    public init(accessMode: SocketControlMode, preferredSocketPath: String) {
        self.accessMode = accessMode
        self.preferredSocketPath = preferredSocketPath
    }
}
