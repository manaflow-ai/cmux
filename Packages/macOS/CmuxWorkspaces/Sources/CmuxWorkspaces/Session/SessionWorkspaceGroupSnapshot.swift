public import Foundation

/// Persisted form of a sidebar ``WorkspaceGroup`` inside a window's session
/// snapshot.
///
/// Carries the group's identity, display name, collapse/pin state, optional
/// tint and icon, and two complementary ways to locate the anchor workspace
/// across a restore: the in-process `anchorWorkspaceId` hint and the
/// restore-stable `anchorMemberIndex`. The snapshot assembly and restore math
/// that read these fields live in ``SessionSnapshotGroupCoordinator``; the
/// on-disk wire format is owned by the app's `SessionTabManagerSnapshot`,
/// which carries an optional array of these values. Encoding stays
/// byte-identical to the legacy app-target definition: the stored property
/// set and their `Codable` synthesis are unchanged, and the repository
/// encodes with `.sortedKeys`.
public struct SessionWorkspaceGroupSnapshot: Codable, Sendable, Equatable {
    /// The group's stable identity within the snapshot.
    public var id: UUID
    /// The group's display name.
    public var name: String
    /// Whether the group's member rows are collapsed.
    public var isCollapsed: Bool
    /// The workspace whose close dissolves the group. Only meaningful within
    /// a single app run; on restore, each workspace gets a fresh UUID. The
    /// loader prefers `anchorMemberIndex` (restore-stable) and treats this
    /// field as a hint for in-process round-trips.
    public var anchorWorkspaceId: UUID?
    /// 0-based index of the anchor among the group's members in tab order.
    /// Restore-stable: tab order is preserved across restore, so the same
    /// index resolves to the same logical anchor even though workspace UUIDs
    /// change. Older snapshots that omit this field fall back to "first
    /// member by tab order".
    public var anchorMemberIndex: Int?
    /// Whether the group is pinned. Optional for backward compatibility with
    /// snapshots predating pinning.
    public var isPinned: Bool?
    /// Group-level tint override (hex string), or nil to inherit.
    public var customColor: String?
    /// SF Symbol name for the group header icon, or nil for the default.
    public var iconSymbol: String?

    /// Creates a group snapshot (memberwise; mirrors the legacy app-side
    /// default-nil shape so existing call sites compile unchanged).
    public init(
        id: UUID,
        name: String,
        isCollapsed: Bool,
        anchorWorkspaceId: UUID? = nil,
        anchorMemberIndex: Int? = nil,
        isPinned: Bool? = nil,
        customColor: String? = nil,
        iconSymbol: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.anchorWorkspaceId = anchorWorkspaceId
        self.anchorMemberIndex = anchorMemberIndex
        self.isPinned = isPinned
        self.customColor = customColor
        self.iconSymbol = iconSymbol
    }
}
