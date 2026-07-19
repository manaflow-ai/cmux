/// One authorized control-socket command and the authority that admitted it.
public struct SocketClientAuthorizationResult: Sendable, Equatable {
    /// The command after removing any structurally valid capability envelope.
    public let command: String

    /// The authority that admitted this command.
    public let basis: SocketClientAuthorizationBasis

    /// Creates an immutable authorization result.
    public init(command: String, basis: SocketClientAuthorizationBasis) {
        self.command = command
        self.basis = basis
    }
}
