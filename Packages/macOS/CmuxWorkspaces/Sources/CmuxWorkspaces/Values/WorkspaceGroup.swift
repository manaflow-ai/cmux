public import Foundation

/// Named collapsible sidebar group containing zero or more workspaces.
/// The membership relation lives on `Workspace.groupId`; this struct stores
/// the group's identity, display name, collapse/pin state, and the stable
/// header anchor identity.
/// A newly-created group starts with a live workspace anchor. Closing that
/// anchor promotes the first remaining member in `tabs` order. A pinned group
/// with no remaining members transitions to an empty anchor and keeps its
/// header until an explicit Delete Group action removes it. The anchor is
/// rendered implicitly as the group header (there is no separate workspace
/// row).
/// An optional external id gives automation a stable, caller-owned identity
/// for create-if-absent operations; it is scoped to the owning window.
public struct WorkspaceGroup: Identifiable, Equatable, Sendable {
    /// The group's stable identity.
    public let id: UUID
    /// The group's display name.
    public var name: String
    /// Whether the group's member rows are collapsed in the sidebar.
    public var isCollapsed: Bool
    /// Whether the group is pinned.
    public var isPinned: Bool
    /// Current header anchor state.
    public var anchor: WorkspaceGroupAnchor
    /// Group-level color override (hex string). When nil, falls back to the
    /// cwd-config color resolved from `cmux.json` for the anchor's cwd, then
    /// to no tint.
    public var customColor: String?
    /// SF symbol name for the header icon. When nil, defaults to `folder.fill`.
    public var iconSymbol: String?
    /// Stable caller-owned identity used by idempotent group creation.
    public var externalID: String?
    /// Standard retry spelling for ``externalID``.
    public var idempotencyKey: String? {
        externalID
    }
    /// Provenance of the current anchor, used to gate explicit cleanup of an
    /// anchor-only generated workspace.
    public var anchorWorkspaceProvenance: WorkspaceGroupAnchorProvenance
    /// Whether the current anchor is still the cmux-created anchor.
    public var isGeneratedAnchor: Bool {
        anchorWorkspaceProvenance == .generated && liveAnchorWorkspaceId != nil
    }

    /// Stable id used by existing sidebar and socket projections.
    ///
    /// For an empty group this is the placeholder identity, not a live
    /// workspace id. Assigning a new value always promotes that workspace to
    /// the live anchor state.
    public var anchorWorkspaceId: UUID {
        get { anchor.identity }
        set { anchor = .workspace(newValue) }
    }

    /// The live anchor workspace id, or `nil` for an empty group.
    public var liveAnchorWorkspaceId: UUID? { anchor.workspaceId }

    /// Whether this group currently has no live member workspace.
    public var isEmpty: Bool { anchor.isEmpty }

    /// Creates a group (memberwise; mirrors the legacy app-side shape).
    public init(
        id: UUID,
        name: String,
        isCollapsed: Bool,
        isPinned: Bool,
        anchorWorkspaceId: UUID,
        customColor: String?,
        iconSymbol: String?,
        externalID: String? = nil,
        anchorWorkspaceProvenance: WorkspaceGroupAnchorProvenance = .unknown
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.anchor = .workspace(anchorWorkspaceId)
        self.customColor = customColor
        self.iconSymbol = iconSymbol
        self.externalID = externalID
        self.anchorWorkspaceProvenance = anchorWorkspaceProvenance
    }

    /// Creates a group with an explicit live or empty anchor state.
    public init(
        id: UUID,
        name: String,
        isCollapsed: Bool,
        isPinned: Bool,
        anchor: WorkspaceGroupAnchor,
        customColor: String?,
        iconSymbol: String?,
        externalID: String? = nil,
        anchorWorkspaceProvenance: WorkspaceGroupAnchorProvenance = .unknown
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.anchor = anchor
        self.customColor = customColor
        self.iconSymbol = iconSymbol
        self.externalID = externalID
        self.anchorWorkspaceProvenance = anchorWorkspaceProvenance
    }
}
