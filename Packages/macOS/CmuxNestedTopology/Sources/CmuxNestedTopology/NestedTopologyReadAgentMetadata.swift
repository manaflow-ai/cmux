/// Bounded agent identity/status metadata published on a nested read node.
public struct NestedTopologyReadAgentMetadata: Hashable, Codable, Sendable {
    /// Compound agent node ID when the row itself is not the agent.
    public let id: NestedNodeID?
    /// Sanitized agent display label.
    public let label: String?
    /// Normalized presentation status.
    public let status: NestedAgentStatus?
    /// Original provider status token (bounded).
    public let providerRawStatus: String?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case status
        case providerRawStatus = "provider_raw_status"
    }

    /// Creates bounded agent metadata for a public read node.
    public init(
        id: NestedNodeID? = nil,
        label: String? = nil,
        status: NestedAgentStatus? = nil,
        providerRawStatus: String? = nil
    ) {
        self.id = id
        self.label = label.map {
            NestedDisplayStringSanitizer.sanitize(
                $0,
                maxUTF8ByteCount: NestedTopologyLimits.default.maxDisplayTitleUTF8ByteCount
            )
        }
        self.status = status
        self.providerRawStatus = providerRawStatus.map {
            NestedDisplayStringSanitizer.sanitize(
                $0,
                maxUTF8ByteCount: NestedTopologyLimits.default.maxProviderRawStatusUTF8ByteCount
            )
        }
    }
}
