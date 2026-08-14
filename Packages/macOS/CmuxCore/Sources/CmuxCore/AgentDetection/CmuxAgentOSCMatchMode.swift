internal import Foundation

/// Comparison mode for one OSC sequence condition.
public enum CmuxAgentOSCMatchMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Matches the sequence anywhere in the captured OSC stream.
    case contains
    /// Matches only when the stream starts with the sequence.
    case prefix
    /// Matches only when the complete stream equals the sequence.
    case exact

    /// Decodes canonical names and compatibility aliases.
    ///
    /// - Parameter decoder: Decoder positioned at an OSC mode string.
    /// - Throws: ``DecodingError`` when the string is not a supported mode.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "contains", "substring": self = .contains
        case "prefix", "starts-with", "starts_with": self = .prefix
        case "exact", "equals": self = .exact
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: CmuxAgentManifestCodec.localizedReason(
                        "agentManifest.validation.unknownOSCMode",
                        defaultValue: "Unknown OSC match mode '%@'",
                        arguments: [raw]
                    )
                )
            )
        }
    }
}
