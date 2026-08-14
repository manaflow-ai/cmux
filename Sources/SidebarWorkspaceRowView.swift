import Foundation
import CmuxSettings
import SwiftUI

/// Mounts one immutable workspace-row projection below the lazy-list boundary.
struct SidebarWorkspaceRowView: View {
    let snapshot: SidebarWorkspaceRowSnapshot
    let actions: SidebarWorkspaceRowActions
    /// Immutable palette snapshot captured above the lazy-list boundary.
    let chromePalette: ChromePalette
    let shouldCollectWorkspaceDropTargets: Bool

    var body: some View {
        TabItemView(snapshot: snapshot, actions: actions, chromePalette: chromePalette)
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
            .padding(
                .leading,
                snapshot.groupId != nil ? SidebarWorkspaceGroupingMetrics.memberIndent : 0
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}
