import CMUXMobileCore
public import Foundation

/// The phone's view of ONE Mac's workspaces: the per-Mac source of truth behind
/// the aggregated multi-Mac workspace list. The published flat list (and group
/// sections) is a PURE DERIVATION over every Mac's `MacWorkspaceState` — see
/// ``MobileWorkspaceAggregation``. Nothing assigns the flat list directly; it is
/// always `derive(statesByMac:foregroundMacDeviceID:)`, so a stale or
/// half-merged aggregate is unrepresentable.
///
/// Deliberately transport-agnostic. Today each entry is fed by a direct
/// phone→Mac live subscription (N connections). The planned end-state routes
/// every Mac through a single Durable Object that the phone holds ONE connection
/// to, which delivers per-Mac deltas; the data model and the derivation are
/// identical either way — only the writer of these entries changes. So this type
/// carries no connection/RPC/route detail, only the observable facts about a
/// Mac's workspaces.
public struct MacWorkspaceState: Identifiable, Equatable, Sendable {
    /// The stable device id of the Mac this state describes. Also the dictionary
    /// key in the aggregate, and the `id` for `Identifiable`.
    public var macDeviceID: String
    /// The app-instance tag of the Mac pairing this state describes ("default",
    /// "nightly", a dev tag), or `nil` for a legacy untagged pairing. Sibling
    /// builds of one physical Mac are separate entries distinguished by tag.
    public var instanceTag: String?
    /// The Mac's user-facing display name, for per-Mac sections/labels.
    public var displayName: String?
    /// This Mac's workspaces, each already tagged with `macDeviceID` so the
    /// derived list can group and filter by machine without re-stamping.
    public var workspaces: [MobileWorkspacePreview]
    /// This Mac's workspace groups, in section order (empty when the Mac reports
    /// none or is too old to emit them).
    public var groups: [MobileWorkspaceGroupPreview]
    /// Whether ``groups`` came from a complete host snapshot. A false value
    /// means an empty list can still be a loading or capability projection.
    public var workspaceGroupsAreAuthoritative: Bool
    /// Liveness of THIS Mac's data, so the UI can show per-Mac
    /// connecting/reconnecting/offline and the derivation can decide whether a
    /// dropped Mac's last-known rows stay (greyed) or are dropped.
    public var status: MobileMacConnectionStatus
    /// Workspace actions supported by this Mac.
    public var actionCapabilities: MobileWorkspaceActionCapabilities

    /// Stable identity for SwiftUI lists and dictionaries. Sibling builds of
    /// one physical Mac are distinct entries, so identity carries the tag; the
    /// separator is the same U+001F unit separator `MobilePairedMac.pairingID`
    /// uses (this package deliberately does not depend on that module).
    public var id: String {
        CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ).id
    }

    /// Create one per-Mac workspace state snapshot.
    public init(
        macDeviceID: String,
        instanceTag: String? = nil,
        displayName: String? = nil,
        workspaces: [MobileWorkspacePreview] = [],
        groups: [MobileWorkspaceGroupPreview] = [],
        workspaceGroupsAreAuthoritative: Bool = false,
        status: MobileMacConnectionStatus = .reconnecting,
        actionCapabilities: MobileWorkspaceActionCapabilities = .none
    ) {
        let identity = CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        self.macDeviceID = identity.macDeviceID
        self.instanceTag = identity.instanceTag
        self.displayName = displayName
        self.workspaces = workspaces
        self.groups = groups
        self.workspaceGroupsAreAuthoritative = workspaceGroupsAreAuthoritative
        self.status = status
        self.actionCapabilities = actionCapabilities
    }
}
