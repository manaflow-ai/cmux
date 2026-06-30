import CmuxSettings
import CoreGraphics
import Foundation

struct WorkspaceRowControlsSnapshot: Equatable {
    let controls: [WorkspaceRowControlOption]
    let layout: WorkspaceRowControlsLayout

    static func resolved(
        workspaceControlsBetaEnabled: Bool,
        workspaceTasksBetaEnabled: Bool,
        configuredControls: [WorkspaceRowControlOption],
        fontScale: CGFloat
    ) -> WorkspaceRowControlsSnapshot {
        let controls: [WorkspaceRowControlOption]
        if workspaceControlsBetaEnabled {
            let taskFiltered = workspaceTasksBetaEnabled
                ? configuredControls
                : configuredControls.filter { $0 != .tasks }
            controls = WorkspaceRowControlSanitizer().sanitized(taskFiltered)
        } else if workspaceTasksBetaEnabled {
            controls = [.tasks, .close]
        } else {
            controls = WorkspaceRowControlOption.defaultControls
        }
        return WorkspaceRowControlsSnapshot(
            controls: controls,
            layout: WorkspaceRowControlsLayout(controlCount: controls.count, fontScale: fontScale)
        )
    }
}
