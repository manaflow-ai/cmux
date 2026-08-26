/// A semantic operation advertised by a nested-topology provider.
///
/// Values are open and retained verbatim so unknown future capabilities do not
/// disappear when snapshots pass through cmux.
public struct NestedProviderCapability: Codable, Comparable, Hashable, Sendable {
    /// Provider supports coherent topology snapshots.
    public static let topologySnapshot = NestedProviderCapability(rawValue: "topology.snapshot.v1")

    /// Provider supports incremental topology events.
    public static let topologyEvents = NestedProviderCapability(rawValue: "topology.events.v1")

    /// Provider supports focusing virtual descendants.
    public static let topologyFocus = NestedProviderCapability(rawValue: "topology.focus.v1")

    /// Provider supports renaming virtual descendants.
    public static let topologyRename = NestedProviderCapability(rawValue: "topology.rename.v1")

    /// Provider supports sending input to a nested pane.
    public static let paneInput = NestedProviderCapability(rawValue: "pane.input.v1")

    /// Provider supports creating provider-owned pane splits.
    public static let paneSplit = NestedProviderCapability(rawValue: "pane.split.v1")

    /// Provider supports prompting a nested agent.
    public static let agentPrompt = NestedProviderCapability(rawValue: "agent.prompt.v1")

    /// Provider-defined opaque semantic capability preserved byte-for-byte on the wire.
    public let rawValue: String

    /// Creates a semantic capability.
    ///
    /// Snapshot validation rejects empty, oversized, or control-bearing values.
    ///
    /// - Parameter rawValue: Provider capability token.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Compares capability tokens by their exact UTF-8 representation.
    public static func == (
        lhs: NestedProviderCapability,
        rhs: NestedProviderCapability
    ) -> Bool {
        ExactUTF8String(lhs.rawValue) == ExactUTF8String(rhs.rawValue)
    }

    /// Hashes the exact UTF-8 capability token.
    ///
    /// - Parameter hasher: Hasher receiving the capability token.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ExactUTF8String(rawValue))
    }

    /// Orders capabilities by stable raw value.
    ///
    /// - Parameters:
    ///   - lhs: Left capability.
    ///   - rhs: Right capability.
    /// - Returns: `true` when the left token sorts before the right token.
    public static func < (lhs: NestedProviderCapability, rhs: NestedProviderCapability) -> Bool {
        ExactUTF8String(lhs.rawValue) < ExactUTF8String(rhs.rawValue)
    }

    /// Decodes a capability from its byte-exact wire token.
    ///
    /// - Parameter decoder: Decoder containing the token.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(ExactUTF8String.self).value
    }

    /// Encodes a capability as a byte-exact wire token.
    ///
    /// - Parameter encoder: Encoder receiving the token.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ExactUTF8String(rawValue))
    }
}
