import CMUXMobileCore
import Foundation

/// Plain-value snapshot of one known workspace group offered as a mute toggle
/// in the Notification Filters screen. Derived from the live shell store's
/// group previews (name + owning Mac) so the view below the `Form` boundary
/// never holds a store reference.
public struct MobilePushFilterGroupOption: Identifiable, Equatable, Sendable {
    /// The Mac-local group id the rule stores and pushes carry.
    public let groupId: String
    /// The group's user-facing name (also snapshotted into the rule).
    public let name: String
    /// The owning Mac's stable device id, when known.
    public let macDeviceId: String?
    /// The owning Mac's display name, for the row caption.
    public let macDisplayName: String?

    /// Mac-scoped identity: two Macs may reuse the same Mac-local group id.
    public var id: String { "\(macDeviceId ?? "")\u{1F}\(groupId)" }

    /// Creates a group option snapshot.
    public init(
        groupId: String,
        name: String,
        macDeviceId: String?,
        macDisplayName: String?
    ) {
        self.groupId = groupId
        self.name = name
        self.macDeviceId = macDeviceId
        self.macDisplayName = macDisplayName
    }

    /// Whether `rule` is this group's mute rule (same group id, and the same
    /// Mac when the rule carries a Mac scope).
    public func matches(_ rule: MobilePushFilterRule) -> Bool {
        guard let ruleGroupId = rule.groupId,
              ruleGroupId.caseInsensitiveCompare(groupId) == .orderedSame
        else { return false }
        guard let ruleMacDeviceId = rule.macDeviceId else { return true }
        guard let macDeviceId else { return false }
        return ruleMacDeviceId.caseInsensitiveCompare(macDeviceId) == .orderedSame
    }
}
