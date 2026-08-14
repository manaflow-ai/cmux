internal import Foundation

/// One ordered terminal-state rule. Its conditions are OR-ed.
public struct CmuxAgentStateRule: Codable, Equatable, Hashable, Sendable {
    /// Stable identifier shown in diagnostics.
    public var id: String
    /// Classification produced when any condition matches.
    public var state: CmuxAgentDetectionState
    /// Case-insensitive literal screen fragments.
    public var screenContains: [String]
    /// Regular expressions evaluated against captured screen text.
    public var screenRegex: [CmuxAgentRegexPattern]
    /// OSC sequence conditions evaluated against captured OSC data.
    public var osc: [CmuxAgentOSCSequenceRule]

    /// Creates an ordered state rule.
    public init(
        id: String,
        state: CmuxAgentDetectionState,
        screenContains: [String] = [],
        screenRegex: [CmuxAgentRegexPattern] = [],
        osc: [CmuxAgentOSCSequenceRule] = []
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.state = state
        self.screenContains = screenContains
        self.screenRegex = screenRegex
        self.osc = osc
    }

    private enum CodingKeys: String, CodingKey {
        case id, state, screenContains, screenRegex, osc, oscSequences
    }

    /// Decodes scalar-or-array screen literals and the compatibility
    /// `oscSequences` spelling while rejecting ambiguous OSC declarations.
    ///
    /// - Parameter decoder: Decoder positioned at one state-rule object.
    /// - Throws: ``DecodingError`` for invalid fields or conflicting OSC keys.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.osc), container.contains(.oscSequences) {
            throw DecodingError.dataCorruptedError(
                forKey: .osc,
                in: container,
                debugDescription: CmuxAgentManifestCodec.localizedReason(
                    "agentManifest.validation.oscFieldConflict",
                    defaultValue: "Declare only one of 'osc' or 'oscSequences'"
                )
            )
        }
        let oscKey: CodingKeys = container.contains(.osc) ? .osc : .oscSequences
        self.init(
            id: try container.decode(String.self, forKey: .id),
            state: try container.decode(CmuxAgentDetectionState.self, forKey: .state),
            screenContains: try Self.decodeStrings(container, key: .screenContains),
            screenRegex: try container.decodeIfPresent(
                [CmuxAgentRegexPattern].self,
                forKey: .screenRegex
            ) ?? [],
            osc: try container.decodeIfPresent(
                [CmuxAgentOSCSequenceRule].self,
                forKey: oscKey
            ) ?? []
        )
    }

    /// Encodes only the canonical `osc` spelling.
    ///
    /// - Parameter encoder: Encoder receiving the canonical rule object.
    /// - Throws: Any error reported by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(state, forKey: .state)
        try container.encode(screenContains, forKey: .screenContains)
        try container.encode(screenRegex, forKey: .screenRegex)
        try container.encode(osc, forKey: .osc)
    }

    private static func decodeStrings(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> [String] {
        if let values = try? container.decode([String].self, forKey: key) {
            return values
        }
        if let value = try container.decodeIfPresent(String.self, forKey: key) {
            return [value]
        }
        return []
    }
}
