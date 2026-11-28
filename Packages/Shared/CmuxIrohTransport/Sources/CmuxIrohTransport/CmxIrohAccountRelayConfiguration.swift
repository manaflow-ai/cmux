/// Complete account-synchronized relay configuration.
///
/// The active mode, dormant managed selection, and saved custom definitions
/// have independent lifecycles. Switching modes therefore never destroys the
/// configuration a user may switch back to later.
public struct CmxIrohAccountRelayConfiguration: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Equatable, Sendable {
        case automatic
        case managed
        case custom
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case selectedManagedRelayIDs = "selectedManagedRelayIds"
        case customRelays
    }

    public let mode: Mode
    public let selectedManagedRelayIDs: Set<String>
    public let customRelays: [CmxIrohCustomRelayDefinition]

    public init(
        mode: Mode,
        selectedManagedRelayIDs: Set<String>,
        customRelays: [CmxIrohCustomRelayDefinition]
    ) throws {
        guard selectedManagedRelayIDs.count <= CmxIrohRelayPolicyVerifier.maximumRelayCount,
              selectedManagedRelayIDs.allSatisfy(Self.isSafeID),
              customRelays.count <= CmxIrohRelayPolicyVerifier.maximumRelayCount,
              Set(customRelays.map(\.id)).count == customRelays.count,
              Set(customRelays.map(\.url)).count == customRelays.count,
              selectedManagedRelayIDs.isDisjoint(with: Set(customRelays.map(\.id))),
              mode != .managed || !selectedManagedRelayIDs.isEmpty,
              mode != .custom || !customRelays.isEmpty else {
            throw CmxIrohRelayPolicyError.invalidSelection
        }
        self.mode = mode
        self.selectedManagedRelayIDs = selectedManagedRelayIDs
        self.customRelays = customRelays
    }

    /// Safe empty configuration used before an account has saved a preference.
    public static var automatic: Self {
        Self(
            validatedMode: .automatic,
            selectedManagedRelayIDs: [],
            customRelays: []
        )
    }

    public static func managed(_ relayIDs: Set<String>) throws -> Self {
        try Self(mode: .managed, selectedManagedRelayIDs: relayIDs, customRelays: [])
    }

    public static func custom(_ relays: [CmxIrohCustomRelayDefinition]) throws -> Self {
        try Self(mode: .custom, selectedManagedRelayIDs: [], customRelays: relays)
    }

    /// Active preference derived from the independent configuration fields.
    public var activePreference: CmxIrohAccountRelayPreference {
        switch mode {
        case .automatic:
            .automatic
        case .managed:
            .managed(selectedManagedRelayIDs)
        case .custom:
            .custom(customRelays)
        }
    }

    /// Replaces only the active mode or managed selection.
    public func updatingActivePreference(
        _ preference: CmxIrohAccountRelayPreference
    ) throws -> Self {
        switch preference {
        case .automatic:
            try Self(
                mode: .automatic,
                selectedManagedRelayIDs: selectedManagedRelayIDs,
                customRelays: customRelays
            )
        case let .managed(relayIDs):
            try Self(
                mode: .managed,
                selectedManagedRelayIDs: relayIDs,
                customRelays: customRelays
            )
        case .custom:
            try Self(
                mode: .custom,
                selectedManagedRelayIDs: selectedManagedRelayIDs,
                customRelays: customRelays
            )
        }
    }

    /// Replaces saved custom metadata without implicitly changing active mode.
    /// Removing the final active custom relay safely returns to automatic mode.
    public func replacingCustomRelays(
        _ relays: [CmxIrohCustomRelayDefinition]
    ) throws -> Self {
        try Self(
            mode: mode == .custom && relays.isEmpty ? .automatic : mode,
            selectedManagedRelayIDs: selectedManagedRelayIDs,
            customRelays: relays
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(Mode.self, forKey: .mode)
        let orderedManagedIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .selectedManagedRelayIDs
        ) ?? []
        guard Set(orderedManagedIDs).count == orderedManagedIDs.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .selectedManagedRelayIDs,
                in: container,
                debugDescription: "Duplicate managed relay identifier"
            )
        }
        do {
            try self.init(
                mode: mode,
                selectedManagedRelayIDs: Set(orderedManagedIDs),
                customRelays: container.decodeIfPresent(
                    [CmxIrohCustomRelayDefinition].self,
                    forKey: .customRelays
                ) ?? []
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid relay configuration")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        _ = try Self(
            mode: mode,
            selectedManagedRelayIDs: selectedManagedRelayIDs,
            customRelays: customRelays
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(selectedManagedRelayIDs.sorted(), forKey: .selectedManagedRelayIDs)
        try container.encode(customRelays, forKey: .customRelays)
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

    private init(
        validatedMode mode: Mode,
        selectedManagedRelayIDs: Set<String>,
        customRelays: [CmxIrohCustomRelayDefinition]
    ) {
        self.mode = mode
        self.selectedManagedRelayIDs = selectedManagedRelayIDs
        self.customRelays = customRelays
    }
}
