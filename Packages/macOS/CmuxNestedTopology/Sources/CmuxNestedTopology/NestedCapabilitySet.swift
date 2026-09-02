/// Set of negotiated nested-provider capabilities.
public struct NestedCapabilitySet: Hashable, Sendable {
    /// Contained capability tokens.
    public var capabilities: Set<NestedProviderCapability>

    /// Creates a capability set.
    ///
    /// - Parameter capabilities: Negotiated capabilities.
    public init(capabilities: Set<NestedProviderCapability> = []) {
        self.capabilities = capabilities
    }

    /// Whether the set contains the given capability.
    public func contains(_ capability: NestedProviderCapability) -> Bool {
        capabilities.contains(capability)
    }

    /// Inserts a capability.
    public mutating func insert(_ capability: NestedProviderCapability) {
        capabilities.insert(capability)
    }

    /// Intersection used when authorizing an action against both cmux support and provider ads.
    public func intersection(_ other: NestedCapabilitySet) -> NestedCapabilitySet {
        NestedCapabilitySet(capabilities: capabilities.intersection(other.capabilities))
    }

    /// Sorted capability raw values for deterministic encoding/tests.
    public var sortedRawValues: [String] {
        capabilities.map(\.rawValue).sorted()
    }
}

extension NestedCapabilitySet: Codable {
    private enum CodingKeys: String, CodingKey {
        case capabilities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try container.decodeIfPresent([NestedProviderCapability].self, forKey: .capabilities) ?? []
        self.init(capabilities: Set(values))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let sorted = capabilities.sorted { $0.rawValue < $1.rawValue }
        try container.encode(sorted, forKey: .capabilities)
    }
}
