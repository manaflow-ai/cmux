/// Last broker preference and the exact subset safely resolved on this device.
public struct CmxIrohPersistedRelayPreference: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case requested
        case effective
        case revision
        case effectivePolicySequence
        case staleRelayIDs
    }

    /// Complete account configuration requested by the broker.
    public let requested: CmxIrohAccountRelayConfiguration

    /// Preference subset that was last safely honored, or `nil` for direct-only.
    public let effective: CmxIrohAccountRelayPreference?

    /// Monotonic broker preference revision.
    public let revision: Int64

    /// Signed policy sequence used to resolve the effective managed selection.
    public let effectivePolicySequence: Int64?

    /// Requested managed IDs missing from that policy.
    public let staleRelayIDs: Set<String>

    public init(
        requested: CmxIrohAccountRelayConfiguration,
        effective: CmxIrohAccountRelayPreference?,
        revision: Int64,
        effectivePolicySequence: Int64?,
        staleRelayIDs: Set<String>
    ) {
        self.requested = requested
        self.effective = effective
        self.revision = revision
        self.effectivePolicySequence = effectivePolicySequence
        self.staleRelayIDs = staleRelayIDs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let configuration = try? container.decode(
            CmxIrohAccountRelayConfiguration.self,
            forKey: .requested
        ) {
            requested = configuration
        } else {
            let legacy = try container.decode(
                CmxIrohAccountRelayPreference.self,
                forKey: .requested
            )
            switch legacy {
            case .automatic:
                requested = .automatic
            case let .managed(ids):
                requested = try .managed(ids)
            case let .custom(relays):
                requested = try .custom(relays)
            }
        }
        effective = try container.decodeIfPresent(
            CmxIrohAccountRelayPreference.self,
            forKey: .effective
        )
        revision = try container.decode(Int64.self, forKey: .revision)
        effectivePolicySequence = try container.decodeIfPresent(
            Int64.self,
            forKey: .effectivePolicySequence
        )
        staleRelayIDs = try container.decode(Set<String>.self, forKey: .staleRelayIDs)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requested, forKey: .requested)
        try container.encodeIfPresent(effective, forKey: .effective)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(effectivePolicySequence, forKey: .effectivePolicySequence)
        try container.encode(staleRelayIDs, forKey: .staleRelayIDs)
    }
}
