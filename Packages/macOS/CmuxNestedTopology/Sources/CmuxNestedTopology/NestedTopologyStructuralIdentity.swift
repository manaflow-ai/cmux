public import Foundation

/// Structural topology identity used for equality/diffing without display titles.
///
/// Titles may thrash or lock independently of parentage, focus, order, and status.
public struct NestedTopologyStructuralIdentity: Hashable, Sendable {
    /// Attachment that owns this snapshot.
    public let attachmentID: UUID
    /// Host cmux stable surface identity.
    public let hostStableSurfaceID: UUID
    /// Provider handshake identity fields (no free-form labels).
    public let providerKind: NestedProviderKind
    /// Provider instance identity.
    public let providerInstanceID: NestedProviderInstanceID
    /// Workspace IDs in deterministic order.
    public let workspaceIDs: [NestedNodeID]
    /// Tabs without display titles.
    public let tabs: [NestedStructuralTab]
    /// Panes without display titles.
    public let panes: [NestedStructuralPane]
    /// Agents without display titles (status retained).
    public let agents: [NestedStructuralAgent]
    /// Focused compound IDs.
    public let focus: NestedFocus

    /// Creates a structural identity value.
    public init(
        attachmentID: UUID,
        hostStableSurfaceID: UUID,
        providerKind: NestedProviderKind,
        providerInstanceID: NestedProviderInstanceID,
        workspaceIDs: [NestedNodeID],
        tabs: [NestedStructuralTab],
        panes: [NestedStructuralPane],
        agents: [NestedStructuralAgent],
        focus: NestedFocus
    ) {
        self.attachmentID = attachmentID
        self.hostStableSurfaceID = hostStableSurfaceID
        self.providerKind = providerKind
        self.providerInstanceID = providerInstanceID
        self.workspaceIDs = workspaceIDs
        self.tabs = tabs
        self.panes = panes
        self.agents = agents
        self.focus = focus
    }
}
