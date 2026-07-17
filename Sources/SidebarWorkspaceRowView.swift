import Foundation
import SwiftUI

/// Mounts one immutable workspace-row projection inside its table cell's
/// hosted SwiftUI root. Rows receive value snapshots plus action closures
/// only; row geometry and hover are owned by the AppKit table.
struct SidebarWorkspaceRowView: View {
    let snapshot: SidebarWorkspaceRowSnapshot
    let actions: SidebarWorkspaceRowActions

    var body: some View {
        TabItemView(snapshot: snapshot, actions: actions)
            .equatable()
            .id(snapshot.workspaceId)
            .accessibilityIdentifier("sidebarWorkspace.\(snapshot.workspaceId.uuidString)")
            .padding(
                .leading,
                snapshot.groupId != nil ? SidebarWorkspaceGroupingMetrics.memberIndent : 0
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}
