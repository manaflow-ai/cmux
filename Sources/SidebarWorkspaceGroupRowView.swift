import Foundation
import SwiftUI

/// Mounts one immutable workspace-group projection inside its table cell's
/// hosted SwiftUI root. Row geometry and hover are owned by the AppKit table.
struct SidebarWorkspaceGroupRowView: View {
    let header: SidebarWorkspaceGroupHeaderView
    let groupId: UUID
    let anchorWorkspaceId: UUID

    var body: some View {
        header
            .equatable()
            .id(anchorWorkspaceId)
            .accessibilityIdentifier("sidebarWorkspaceGroup.\(groupId.uuidString)")
    }
}
