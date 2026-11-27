/// A structurally parsed capability-bearing control-socket command.
public struct SocketClientCapabilityCommand: Sendable {
    static let wirePrefix = "_cmux_capability_v1"

    /// Opaque capability presented by the client.
    public let capability: String

    /// Original control-socket command without the capability envelope.
    public let command: String

    /// Parses a capability envelope without validating its signature.
    ///
    /// - Parameter line: Raw socket command line.
    public init?(_ line: String) {
        let prefix = Self.wirePrefix + " "
        guard line.hasPrefix(prefix) else { return nil }
        let remainder = line.dropFirst(prefix.count)
        guard let separator = remainder.firstIndex(of: " ") else { return nil }
        let capability = String(remainder[..<separator])
        let command = String(remainder[remainder.index(after: separator)...])
        guard !capability.isEmpty, !command.isEmpty else { return nil }
        self.capability = capability
        self.command = command
    }
}
