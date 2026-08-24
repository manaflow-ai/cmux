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
        // Lossy element decode that can never stall: the element wrapper's
        // initializer swallows its own failure, so the unkeyed container
        // always advances, including for `null` and non-object elements
        // (a bare `try?` skip loops forever on those).
        let lossy = try container.decodeIfPresent(
            [MobilePushFilterRuleLossy].self,
            forKey: .rules
        ) ?? []
        self.rules = Array(
            lossy.compactMap(\.rule).prefix(Self.maxRuleCount)
        )
    }

    /// The canonical wire bytes for this document (stable key order, so equal
    /// documents always serialize identically for sync-dedup comparisons).
    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Decodes from ANY JSON element without ever throwing, carrying the rule when
/// the element satisfies the wire contract and `nil` otherwise. This is what
/// makes the rules decode lossy per element instead of failing (or looping on)
/// the whole document.
private struct MobilePushFilterRuleLossy: Decodable {
    let rule: MobilePushFilterRule?

    init(from decoder: any Decoder) {
        self.rule = try? MobilePushFilterRule(from: decoder)
    }
}
