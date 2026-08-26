/// Deterministic, duplicate-free set of semantic provider capabilities.
public struct NestedProviderCapabilities: Codable, Equatable, Sendable {
    /// Capability values in stable raw-value order.
    public let values: [NestedProviderCapability]

    /// Creates a deterministic capability set.
    ///
    /// - Parameter values: Possibly unordered or duplicate capability values.
    public init(_ values: [NestedProviderCapability]) {
        self.values = Array(Set(values)).sorted()
    }

    /// Reports whether the provider advertised a capability.
    ///
    /// - Parameter capability: Semantic capability to find.
    /// - Returns: `true` when the capability is present.
    public func contains(_ capability: NestedProviderCapability) -> Bool {
        values.contains(capability)
    }

    /// Decodes and normalizes a capability collection.
    ///
    /// - Parameter decoder: Decoder containing an array of capability tokens.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode([NestedProviderCapability].self))
    }

    /// Encodes the deterministic capability array.
    ///
    /// - Parameter encoder: Encoder receiving the capability tokens.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}
