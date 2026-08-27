import CmuxFoundation
import SwiftUI

struct SidebarWorkspaceDropTargetWriters: View {
    let bonsplitTargetBridge: SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge
    let bonsplitTargets: [SidebarDropPlanner.WorkspaceDropTarget]
    let reorderTargetBridge: SidebarWorkspaceReorderDropOverlay.TargetBridge
    let reorderTargets: [SidebarWorkspaceReorderDropOverlay.Target]

    var body: some View {
        Color.clear
            .onAppear {
                bonsplitTargetBridge.updateTargets(bonsplitTargets)
                reorderTargetBridge.updateTargets(reorderTargets)
            }
            .onChange(of: bonsplitTargets) { _, targets in
                bonsplitTargetBridge.updateTargets(targets)
            }
            .onChange(of: reorderTargets) { _, targets in
                reorderTargetBridge.updateTargets(targets)
            }
            .onDisappear {
                bonsplitTargetBridge.updateTargets([])
                reorderTargetBridge.updateTargets([])
            }
    }
}
