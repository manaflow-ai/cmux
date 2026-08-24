import Foundation

/// The versioned push-filters document sent verbatim to the cmux web API as
/// `{"version": 1, "rules": [...]}` and persisted locally on the phone.
///
/// Limits are enforced at this boundary: the memberwise initializer caps the
/// rule count at ``maxRuleCount`` and decoding drops any element that violates
/// the per-rule contract (see ``MobilePushFilterRule``) instead of failing the
/// whole document, so one corrupt rule can never wipe the user's filters.
public struct MobilePushFilterRules: Codable, Equatable, Sendable {
    /// The only schema version this build reads and writes.
    public static let currentVersion = 1
    /// The most rules the wire contract accepts in one document.
    public static let maxRuleCount = 64

    /// The document schema version (`1`).
    public let version: Int
    /// The mute rules, in the user's authored order, at most ``maxRuleCount``.
    public let rules: [MobilePushFilterRule]

    /// Creates a version-1 document, truncating past ``maxRuleCount``.
    public init(rules: [MobilePushFilterRule]) {
        self.version = Self.currentVersion
        self.rules = Array(rules.prefix(Self.maxRuleCount))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? Self.currentVersion
        var rulesContainer = try container.nestedUnkeyedContainer(forKey: .rules)
        var decoded: [MobilePushFilterRule] = []
        while !rulesContainer.isAtEnd {
            if let rule = try? rulesContainer.decode(MobilePushFilterRule.self) {
                if decoded.count < Self.maxRuleCount {
                    decoded.append(rule)
                }
            } else {
                // A failed element decode does not advance the container.
                // Consume the invalid element so the loop can continue.
                _ = try? rulesContainer.decode(MobilePushFilterRuleSkip.self)
            }
        }
        self.rules = decoded
    }

    /// The canonical wire bytes for this document (stable key order, so equal
    /// documents always serialize identically for sync-dedup comparisons).
    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Decodes successfully from any JSON element without reading it, letting the
/// lossy rules decode skip an invalid entry.
private struct MobilePushFilterRuleSkip: Decodable {}
