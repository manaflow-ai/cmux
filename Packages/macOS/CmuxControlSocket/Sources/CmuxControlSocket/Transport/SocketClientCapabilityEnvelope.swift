/// Wraps one control-socket command with an inherited terminal capability.
public struct SocketClientCapabilityEnvelope: Sendable {
    /// Environment key exported only into cmux-created terminal processes.
    public static let environmentKey = "CMUX_SOCKET_CAPABILITY"

    private static let wirePrefix = "_cmux_capability_v1"

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
        "\(Self.wirePrefix) \(capability) \(command)"
    }

    /// Parses a capability envelope without validating its signature.
    ///
    /// - Parameter line: Raw socket command line.
    /// - Returns: The presented capability and original command, or `nil` when
    ///   `line` is not a structurally valid capability envelope.
    public static func unwrap(_ line: String) -> (capability: String, command: String)? {
        let prefix = wirePrefix + " "
        guard line.hasPrefix(prefix) else { return nil }
        let remainder = line.dropFirst(prefix.count)
        guard let separator = remainder.firstIndex(of: " ") else { return nil }
        let capability = String(remainder[..<separator])
        let command = String(remainder[remainder.index(after: separator)...])
        guard !capability.isEmpty, !command.isEmpty else { return nil }
        return (capability, command)
    }
}
