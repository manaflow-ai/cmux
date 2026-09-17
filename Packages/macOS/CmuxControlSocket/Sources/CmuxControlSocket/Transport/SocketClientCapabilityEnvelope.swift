/// Wraps one control-socket command with an inherited terminal capability.
public struct SocketClientCapabilityEnvelope: Sendable {
    /// Environment key exported only into cmux-created terminal processes.
    public static let environmentKey = "CMUX_SOCKET_CAPABILITY"

    /// Opaque capability presented by this envelope.
    public let capability: String

    /// Creates an envelope presenter for a non-empty, single-token capability.
    ///
    /// - Parameter capability: Opaque capability issued by
    ///   ``SocketClientCapabilityAuthority``.
    public init?(capability: String) {
        guard !capability.isEmpty,
              capability.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace }) else {
            return nil
        }
        self.capability = capability
    }

    /// Prefixes a command with this envelope's capability.
    ///
    /// - Parameter command: One newline-free control-socket command.
    /// - Returns: The authenticated wire command.
    public func wrap(_ command: String) -> String {
        "\(SocketClientCapabilityCommand.wirePrefix) \(capability) \(command)"
    }

}
