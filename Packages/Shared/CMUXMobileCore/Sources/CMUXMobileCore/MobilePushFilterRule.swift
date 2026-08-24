import Foundation

/// One phone-authored push mute rule, encoded verbatim onto the wire as
/// `{"id": "<uuid>", "enabled": true, "groupId"?, "groupName"?, "macDeviceId"?,
/// "titlePattern"?}` (camelCase keys, exactly this shape).
///
/// A rule is only constructible through ``validated(id:enabled:groupId:groupName:macDeviceId:titlePattern:)``
/// (or `Decodable`, which funnels through it), so an instance always carries at
/// least one of `groupId`/`groupName`/`titlePattern` and every string is within
/// ``maxStringLength``. `enabled` stays mutable so a Settings toggle can flip a
/// rule without re-validating its criteria.
public struct MobilePushFilterRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// The longest string the wire contract accepts for any rule field.
    public static let maxStringLength = 200

    /// The rule's stable identity, minted on the phone.
    public let id: UUID
    /// Whether the rule participates in matching. Disabled rules stay authored
    /// and synced but never mute anything.
    public var enabled: Bool
    /// Mac-local workspace-group id criterion (case-insensitive equality).
    public let groupId: String?
    /// Workspace-group display-name criterion (trimmed, case-insensitive
    /// equality). Kept alongside ``groupId`` so a renamed-but-same group and a
    /// same-named group on a rebuilt Mac both keep matching.
    public let groupName: String?
    /// Owning-Mac scope (case-insensitive equality) snapshotted when the rule
    /// was authored, so two Macs with colliding Mac-local group ids stay apart.
    public let macDeviceId: String?
    /// Case-insensitive `NSRegularExpression` searched anywhere in the push
    /// title. An invalid pattern fails the criterion (never mutes).
    public let titlePattern: String?

    /// Creates a rule when the criteria satisfy the wire contract: at least one
    /// of `groupId`/`groupName`/`titlePattern` present (whitespace-only strings
    /// count as absent) and no string beyond ``maxStringLength``.
    /// - Returns: The rule, or `nil` when the contract is violated.
    public static func validated(
        id: UUID = UUID(),
        enabled: Bool = true,
        groupId: String? = nil,
        groupName: String? = nil,
        macDeviceId: String? = nil,
        titlePattern: String? = nil
    ) -> MobilePushFilterRule? {
        let groupId = normalized(groupId)
        let groupName = normalized(groupName)
        let macDeviceId = normalized(macDeviceId)
        let titlePattern = normalized(titlePattern)
        guard groupId != nil || groupName != nil || titlePattern != nil else {
            return nil
        }
        for value in [groupId, groupName, macDeviceId, titlePattern] {
            if let value, value.count > maxStringLength { return nil }
        }
        return MobilePushFilterRule(
            id: id,
            enabled: enabled,
            groupId: groupId,
            groupName: groupName,
            macDeviceId: macDeviceId,
            titlePattern: titlePattern
        )
    }

    private init(
        id: UUID,
        enabled: Bool,
        groupId: String?,
        groupName: String?,
        macDeviceId: String?,
        titlePattern: String?
    ) {
        self.id = id
        self.enabled = enabled
        self.groupId = groupId
        self.groupName = groupName
        self.macDeviceId = macDeviceId
        self.titlePattern = titlePattern
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let rule = Self.validated(
            id: try container.decode(UUID.self, forKey: .id),
            enabled: try container.decode(Bool.self, forKey: .enabled),
            groupId: try container.decodeIfPresent(String.self, forKey: .groupId),
            groupName: try container.decodeIfPresent(String.self, forKey: .groupName),
            macDeviceId: try container.decodeIfPresent(String.self, forKey: .macDeviceId),
            titlePattern: try container.decodeIfPresent(String.self, forKey: .titlePattern)
        ) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Push filter rule violates the wire contract (missing criteria or oversized string)"
            ))
        }
        self = rule
    }

    /// Treats whitespace-only strings as absent while keeping present values
    /// verbatim (matching, not storage, does the trimming).
    private static func normalized(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }
}
