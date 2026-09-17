import CmuxNestedTopology
import Foundation
import SwiftUI

/// Mounts one immutable workspace-row projection below the lazy-list boundary.
struct SidebarWorkspaceRowView: View {
    let snapshot: SidebarWorkspaceRowSnapshot
    let actions: SidebarWorkspaceRowActions
    let shouldCollectWorkspaceDropTargets: Bool
    /// Provider-owned nested topology subtrees for host surfaces in this workspace.
    /// Empty unless the nested-topology beta is enabled and attachments exist.
    var nestedSubtrees: [NestedSidebarSubtreeSnapshot] = []
    var onToggleNestedExpansion: ((UUID) -> Void)? = nil
    /// Focus a nested node under a host surface (capability-gated; beta).
    var onFocusNestedNode: ((UUID, NestedNodeID) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TabItemView(snapshot: snapshot, actions: actions)
                .equatable()
                .id(snapshot.workspaceId)
                .accessibilityIdentifier("sidebarWorkspace.\(snapshot.workspaceId.uuidString)")
                .sidebarWorkspaceFrameAnchor(
                    id: snapshot.workspaceId,
                    isEnabled: shouldCollectWorkspaceDropTargets
                )
                .sidebarPointerFrameReporting(
                    onFrameChange: actions.onPointerFrameChange,
                    onDisappear: actions.onPointerFrameDisappear
                )

            if NestedTopologyController.isEnabled, !nestedSubtrees.isEmpty {
                ForEach(nestedSubtrees, id: \.hostStableSurfaceID) { subtree in
                    NestedSidebarSubtreeView(
                        snapshot: subtree,
                        onToggleExpansion: {
                            onToggleNestedExpansion?(subtree.hostStableSurfaceID)
                        },
                        onFocusNode: { nodeID in
                            onFocusNestedNode?(subtree.hostStableSurfaceID, nodeID)
                        }
                    )
                    .equatable()
                }
            }
        }
        .padding(
            .leading,
            snapshot.groupId != nil ? SidebarWorkspaceGroupingMetrics.memberIndent : 0
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
