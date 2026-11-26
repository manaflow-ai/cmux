import Foundation
import SwiftUI

/// Mounts one immutable workspace-group projection below the lazy-list boundary.
struct SidebarWorkspaceGroupRowView: View {
    let header: SidebarWorkspaceGroupHeaderView
    let groupId: UUID
    let anchorWorkspaceId: UUID
    let shouldCollectWorkspaceDropTargets: Bool
    let onPointerFrameChange: (CGRect) -> Void
    let onPointerFrameDisappear: () -> Void

    var body: some View {
        header
            .equatable()
            .id(anchorWorkspaceId)
            .accessibilityIdentifier("sidebarWorkspaceGroup.\(groupId.uuidString)")
            .sidebarWorkspaceFrameAnchor(
                id: anchorWorkspaceId,
                isEnabled: shouldCollectWorkspaceDropTargets
            )
            .sidebarPointerFrameReporting(
                onFrameChange: onPointerFrameChange,
                onDisappear: onPointerFrameDisappear
            )
    }
}
