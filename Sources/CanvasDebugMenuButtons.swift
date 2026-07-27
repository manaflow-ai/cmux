#if DEBUG
import SwiftUI

struct CanvasDebugMenuButtons: View {
    let workspace: Workspace?
    let openStressWorkspacesWithLoadedSurfaces: () -> Void

    var body: some View {
        Button(
            String(
                localized: "debug.menu.openStressWorkspacesWithLoadedSurfaces",
                defaultValue: "Open Stress Workspaces and Load All Terminals"
            )
        ) {
            openStressWorkspacesWithLoadedSurfaces()
        }

        Button(
            String(
                localized: "debug.menu.showCanvasCommandScrollHint",
                defaultValue: "Show Canvas Scroll Hint"
            )
        ) {
            guard let workspace else { return }
            _ = debugShowCanvasCommandScrollHint(in: workspace)
        }
        .disabled(workspace?.layoutMode != .canvas)
    }
}
#endif
