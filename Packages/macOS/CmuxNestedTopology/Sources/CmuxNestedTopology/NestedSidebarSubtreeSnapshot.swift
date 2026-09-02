public import Foundation

/// Immutable sidebar projection for one host surface's nested topology.
///
/// Follows the snapshot-boundary rule: rows receive this value (+ closures),
/// never an `ObservableObject` store reference.
public struct NestedSidebarSubtreeSnapshot: Hashable, Sendable {
    /// Host stable surface identity.
    public let hostStableSurfaceID: UUID
    /// Attachment identity.
    public let attachmentID: UUID
    /// Provider kind label (sanitized).
    public let providerKind: NestedProviderKind
    /// Attachment connection state.
    public let connectionState: NestedConnectionState
    /// Whether the subtree should render as stale/disconnected.
    public let isStale: Bool
    /// Whether the sidebar section is expanded (owned by the list container).
    public let isExpanded: Bool
    /// Root rows in deterministic order (workspaces first).
    public let roots: [NestedSidebarRowSnapshot]

    /// Creates a sidebar subtree snapshot.
    public init(
        hostStableSurfaceID: UUID,
        attachmentID: UUID,
        providerKind: NestedProviderKind,
        connectionState: NestedConnectionState,
        isStale: Bool,
        isExpanded: Bool,
        roots: [NestedSidebarRowSnapshot]
    ) {
        self.hostStableSurfaceID = hostStableSurfaceID
        self.attachmentID = attachmentID
        self.providerKind = providerKind
        self.connectionState = connectionState
        self.isStale = isStale
        self.isExpanded = isExpanded
        self.roots = roots
    }

    /// Technical accessibility tokens for tests/debug (fixed English).
    ///
    /// VoiceOver-facing UI must localize at the SwiftUI boundary
    /// (``NestedSidebarSubtreeView``) from semantic state instead of this value.
    public var accessibilityLabel: String {
        var parts = ["nested", providerKind.rawValue]
        if isStale {
            parts.append("stale")
        }
        parts.append(connectionState.rawValue)
        return parts.joined(separator: ", ")
    }

    /// Builds a hierarchical sidebar snapshot from a flat read attachment.
    public static func make(
        from attachment: NestedTopologyReadAttachment,
        isExpanded: Bool
    ) -> NestedSidebarSubtreeSnapshot {
        let nodesByParent = Dictionary(grouping: attachment.nodes.filter { $0.parentID != nil }) {
            $0.parentID!
        }
        let roots = attachment.nodes
            .filter { $0.parentID == nil }
            .sorted { lhs, rhs in
                if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
                return lhs.id < rhs.id
            }
            .map { NestedSidebarRowSnapshot.make(from: $0, childrenByParent: nodesByParent) }

        let stale = attachment.state == .stale
            || attachment.state == .disconnected
            || attachment.state == .rejected
            || attachment.state == .incompatible

        return NestedSidebarSubtreeSnapshot(
            hostStableSurfaceID: attachment.hostStableSurfaceID,
            attachmentID: attachment.attachmentID,
            providerKind: attachment.providerKind,
            connectionState: attachment.state,
            isStale: stale,
            isExpanded: isExpanded,
            roots: roots
        )
    }
}

/// One expandable nested row for the sidebar (immutable).
public struct NestedSidebarRowSnapshot: Hashable, Sendable {
    /// Public read node identity/payload.
    public let node: NestedTopologyReadNode
    /// Child rows (provider-owned; never Bonsplit panes).
    public let children: [NestedSidebarRowSnapshot]

    /// Creates a row snapshot.
    public init(node: NestedTopologyReadNode, children: [NestedSidebarRowSnapshot]) {
        self.node = node
        self.children = children
    }

    /// Technical accessibility tokens forwarded from the read node (fixed English).
    ///
    /// VoiceOver UI localizes at ``NestedSidebarSubtreeView`` from semantic state.
    public var accessibilityLabel: String {
        node.accessibilityLabel
    }

    fileprivate static func make(
        from node: NestedTopologyReadNode,
        childrenByParent: [NestedNodeID: [NestedTopologyReadNode]]
    ) -> NestedSidebarRowSnapshot {
        let children = (childrenByParent[node.id] ?? [])
            .sorted { lhs, rhs in
                if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
                return lhs.id < rhs.id
            }
            .map { make(from: $0, childrenByParent: childrenByParent) }
        return NestedSidebarRowSnapshot(node: node, children: children)
    }
}
