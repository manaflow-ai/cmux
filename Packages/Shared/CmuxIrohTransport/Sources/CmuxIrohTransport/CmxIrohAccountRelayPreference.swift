/// Account-synchronized preference for managed or user-defined relays.
public enum CmxIrohAccountRelayPreference: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case relayIDs = "selectedManagedRelayIds"
        case relays = "customRelays"
    }

    private enum Mode: String, Codable {
        case automatic
        case managed
        case custom
    }

    /// Allow every relay authorized by the latest verified managed policy.
    case automatic

    /// Allow only the listed stable identifiers from the managed policy.
    case managed(Set<String>)

    /// Use only the listed custom relays, with no managed-provider fallback.
    case custom([CmxIrohCustomRelayDefinition])

    /// Decodes and validates one account preference.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .automatic:
            self = .automatic
        case .managed:
            let orderedIDs = try container.decode([String].self, forKey: .relayIDs)
            let ids = Set(orderedIDs)
            guard ids.count == orderedIDs.count, Self.isValidManagedIDs(ids) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .relayIDs,
                    in: container,
                    debugDescription: "Invalid managed relay selection"
                )
            }
            self = .managed(ids)
        case .custom:
            let relays = try container.decode([CmxIrohCustomRelayDefinition].self, forKey: .relays)
            guard Self.isValidCustomRelays(relays) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .relays,
                    in: container,
                    debugDescription: "Invalid custom relay selection"
                )
            }
            self = .custom(relays)
        }
    }

    /// Encodes the canonical broker preference schema.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode(Mode.automatic, forKey: .mode)
        case let .managed(ids):
            guard Self.isValidManagedIDs(ids) else {
                throw EncodingError.invalidValue(
                    self,
                    .init(codingPath: encoder.codingPath, debugDescription: "Invalid managed selection")
                )
            }
            try container.encode(Mode.managed, forKey: .mode)
            try container.encode(ids.sorted(), forKey: .relayIDs)
        case let .custom(relays):
            guard Self.isValidCustomRelays(relays) else {
                throw EncodingError.invalidValue(
                    self,
                    .init(codingPath: encoder.codingPath, debugDescription: "Invalid custom selection")
                )
            }
            try container.encode(Mode.custom, forKey: .mode)
            try container.encode(relays, forKey: .relays)
        }
    }

    private static func isValidManagedIDs(_ ids: Set<String>) -> Bool {
        (1 ... CmxIrohRelayPolicyVerifier.maximumRelayCount).contains(ids.count)
            && ids.allSatisfy(isSafeID)
    }

    private static func isValidCustomRelays(_ relays: [CmxIrohCustomRelayDefinition]) -> Bool {
        (1 ... CmxIrohRelayPolicyVerifier.maximumRelayCount).contains(relays.count)
            && Set(relays.map(\.id)).count == relays.count
            && Set(relays.map(\.url)).count == relays.count
    }

    private static func isSafeID(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 95].contains(byte)
        }
    }
}
