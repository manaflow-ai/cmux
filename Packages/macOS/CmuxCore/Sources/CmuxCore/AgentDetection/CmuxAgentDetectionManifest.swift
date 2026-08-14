internal import Foundation

/// A complete declarative process-identity and terminal-state definition.
public struct CmuxAgentDetectionManifest: Codable, Equatable, Hashable, Sendable {
    /// Schema version supported by this release.
    public static let currentSchemaVersion = 1

    /// Manifest schema version.
    public var schemaVersion: Int
    /// Stable agent identifier and user override filename stem.
    public var id: String
    /// Human-readable agent name.
    public var displayName: String
    /// Optional asset-catalog icon name.
    public var iconAssetName: String?
    /// Process identity alternatives.
    public var process: CmuxAgentProcessIdentity
    /// Ordered terminal-state rules.
    public var states: [CmuxAgentStateRule]
    /// Optional durable-session contract.
    public var session: CmuxAgentSessionManifest?
    /// Optional restoration-only admission condition.
    public var restorableWhen: CmuxAgentRestorableCondition?

    /// Creates a manifest with detection-only defaults.
    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: String,
        displayName: String? = nil,
        iconAssetName: String? = nil,
        process: CmuxAgentProcessIdentity = .init(),
        states: [CmuxAgentStateRule] = [],
        session: CmuxAgentSessionManifest? = nil,
        restorableWhen: CmuxAgentRestorableCondition? = nil
    ) {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.schemaVersion = schemaVersion
        self.id = normalizedID
        self.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? normalizedID
        self.iconAssetName = iconAssetName
        self.process = process
        self.states = states
        self.session = session
        self.restorableWhen = restorableWhen
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, displayName, iconAssetName
        case process, states, session, restorableWhen
    }

    /// Decodes optional presentation and lifecycle fields with stable defaults.
    ///
    /// - Parameter decoder: Decoder positioned at one manifest object.
    /// - Throws: ``DecodingError`` when a declared field has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? Self.currentSchemaVersion,
            id: id,
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            iconAssetName: try container.decodeIfPresent(String.self, forKey: .iconAssetName),
            process: try container.decodeIfPresent(CmuxAgentProcessIdentity.self, forKey: .process)
                ?? .init(),
            states: try container.decodeIfPresent([CmuxAgentStateRule].self, forKey: .states) ?? [],
            session: try container.decodeIfPresent(CmuxAgentSessionManifest.self, forKey: .session),
            restorableWhen: try container.decodeIfPresent(
                CmuxAgentRestorableCondition.self,
                forKey: .restorableWhen
            )
        )
    }
}
