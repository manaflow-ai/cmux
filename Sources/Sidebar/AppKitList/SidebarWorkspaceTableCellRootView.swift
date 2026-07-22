import Foundation
import SwiftUI

/// Stable SwiftUI root installed once for a reusable sidebar table cell.
@MainActor
struct SidebarWorkspaceTableCellRootView: View {
    let identity: UUID
    let model: SidebarWorkspaceTableCellModel

    var body: some View {
        Group {
            if let state = model.state {
                state.row.makeContent(
                    state.isPointerHovering,
                    state.contextMenuActions
                )
            } else {
                EmptyView()
            }
        }
    }
}
