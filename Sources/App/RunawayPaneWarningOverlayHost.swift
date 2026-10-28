import SwiftUI

/// Reads the warning center for one window, so a new sample re-renders only
/// this leaf, not the window's content view. Shows no warning while the
/// window shows something other than its workspaces.
struct RunawayPaneWarningOverlayHost: View {
    let center: RunawayPaneWarningCenter
    let workspaceIDs: Set<UUID>
    let isShowingWorkspaces: Bool

    var body: some View {
        RunawayPaneWarningOverlay(
            warning: isShowingWorkspaces
                ? center.warnings.first { workspaceIDs.contains($0.workspaceId) }
                : nil,
            onStop: { center.stopProcessTree($0) },
            onDismiss: { center.dismiss($0) }
        )
    }
}
