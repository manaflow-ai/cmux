public import Foundation

/// How a resumed Vault agent treats the working directory recorded for its
/// session.
///
/// `preserve` restores the recorded working directory; `ignore` launches in the
/// caller's directory instead. The custom Codable spelling accepts the legacy
/// `"none"` alias for `ignore` and round-trips the canonical raw value, so on-disk
/// config and wire payloads stay byte-compatible.
public enum CmuxVaultAgentCWDPolicy: String, Codable, Hashable, Sendable {
    /// Restore the working directory recorded with the session.
    case preserve
    /// Launch in the caller's working directory, ignoring the recorded one.
    case ignore

    /// Decodes a policy from its single-string raw value, accepting `"none"` as a
    /// legacy alias for `ignore`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "preserve": self = .preserve
        case "ignore", "none": self = .ignore
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown Vault cwd policy '\(value)'")
            )
        }
    }

    /// Encodes the canonical raw value as a single string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
