import SwiftUI

/// Reads the warning center for one window, so a new sample re-renders only
/// this leaf, not the window's content view. Shows no warning while the
/// window shows something other than its workspaces.
struct RunawayPaneWarningOverlayHost: View {
    let center: RunawayPaneWarningCenter
    let workspaceIDs: Set<UUID>
    let windowId: UUID
    let isShowingWorkspaces: Bool

    var body: some View {
        RunawayPaneWarningOverlay(
            warning: Self.matchingWarning(
                warnings: center.warnings,
                workspaceIDs: workspaceIDs,
                windowId: windowId,
                windowDockPanelIDs: AppDelegate.shared?.existingWindowDock(forWindowId: windowId)
                    .map { Set($0.panels.keys) } ?? [],
                isShowingWorkspaces: isShowingWorkspaces
            ),
            onStop: { center.stopProcessTree($0) },
            onDismiss: { center.dismiss($0) }
        )
    }

    static func matchingWarning(
        warnings: [RunawayPaneWarning],
        workspaceIDs: Set<UUID>,
        windowId: UUID,
        windowDockPanelIDs: Set<UUID>,
        isShowingWorkspaces: Bool
    ) -> RunawayPaneWarning? {
        if isShowingWorkspaces,
           let workspaceWarning = warnings.first(where: { workspaceIDs.contains($0.workspaceId) }) {
            return workspaceWarning
        }
        return warnings.first {
            $0.workspaceId == windowId && windowDockPanelIDs.contains($0.panelId)
        }
    }
}
