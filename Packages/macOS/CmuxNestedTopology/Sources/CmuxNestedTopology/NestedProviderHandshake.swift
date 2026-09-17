/// Handshake metadata captured after a successful provider ping/negotiate.
public struct NestedProviderHandshake: Hashable, Codable, Sendable {
    /// Provider kind.
    public var providerKind: NestedProviderKind
    /// Live provider instance identity for this connection generation.
    public var providerInstanceID: NestedProviderInstanceID
    /// Provider-reported version string (bounded elsewhere).
    public var version: String
    /// Provider protocol number when known.
    public var protocolNumber: Int?
    /// Negotiated semantic capabilities.
    public var capabilities: NestedCapabilitySet
    /// Whether ``providerInstanceID`` came from durable provider proof (e.g. `ping.instance_id`).
    ///
    /// When `false`, the ID is a cmux-minted connection generation and must not
    /// authorize unattended restore auto-reattach.
    public var instanceIdentityIsDurable: Bool

    enum CodingKeys: String, CodingKey {
        case providerKind = "provider_kind"
        case providerInstanceID = "provider_instance_id"
        case version
        case protocolNumber = "protocol_number"
        case capabilities
        case instanceIdentityIsDurable = "instance_identity_is_durable"
    }

    /// Creates handshake metadata.
    public init(
        providerKind: NestedProviderKind,
        providerInstanceID: NestedProviderInstanceID,
        version: String,
        protocolNumber: Int? = nil,
        capabilities: NestedCapabilitySet = NestedCapabilitySet(),
        instanceIdentityIsDurable: Bool = false
    ) {
        self.providerKind = providerKind
        self.providerInstanceID = providerInstanceID
        self.version = version
        self.protocolNumber = protocolNumber
        self.capabilities = capabilities
        self.instanceIdentityIsDurable = instanceIdentityIsDurable
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerKind = try container.decode(NestedProviderKind.self, forKey: .providerKind)
        providerInstanceID = try container.decode(NestedProviderInstanceID.self, forKey: .providerInstanceID)
        version = try container.decode(String.self, forKey: .version)
        protocolNumber = try container.decodeIfPresent(Int.self, forKey: .protocolNumber)
        capabilities = try container.decodeIfPresent(NestedCapabilitySet.self, forKey: .capabilities)
            ?? NestedCapabilitySet()
        instanceIdentityIsDurable = try container.decodeIfPresent(
            Bool.self,
            forKey: .instanceIdentityIsDurable
        ) ?? false
    }
}
