public import Foundation

/// Pure read-side service that turns attachment records into public projections.
///
/// Owned off the SwiftUI row boundary (app/window scope). Holds one
/// ``NestedTopologyTwoPassRenderer`` so parent maps and title locks remain
/// stable across ticks.
public struct NestedTopologyReadService: Sendable {
    private var renderer: NestedTopologyTwoPassRenderer

    /// Creates a read service.
    public init(renderer: NestedTopologyTwoPassRenderer = NestedTopologyTwoPassRenderer()) {
        self.renderer = renderer
    }

    /// Locks a native title so subsequent projections cannot overwrite it.
    public mutating func lockTitle(
        for key: NestedAssociationKey,
        title: String,
        authority: NestedTitleAuthority
    ) {
        renderer.lockTitle(for: key, title: title, authority: authority)
    }

    /// Projects all attachments for `nested.topology.list`.
    public mutating func list(
        attachments: [NestedAttachmentRecord],
        hostStableSurfaceID: UUID? = nil,
        hostWorkspaceID: String? = nil
    ) -> NestedTopologyReadListResult {
        let filtered = attachments.filter { attachment in
            if let hostStableSurfaceID, attachment.hostStableSurfaceID != hostStableSurfaceID {
                return false
            }
            if let hostWorkspaceID, attachment.hostWorkspaceID != hostWorkspaceID {
                return false
            }
            return true
        }
        return renderer.projectList(attachments: filtered)
    }

    /// Projects one attachment into a sidebar subtree snapshot.
    public mutating func sidebarSubtree(
        for attachment: NestedAttachmentRecord,
        isExpanded: Bool
    ) -> NestedSidebarSubtreeSnapshot {
        let projected = renderer.project(attachment: attachment)
        return .make(from: projected, isExpanded: isExpanded)
    }
}
