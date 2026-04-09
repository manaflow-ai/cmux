// Sources/Island/IslandJumpRouter.swift

import Foundation
#if DEBUG
import Bonsplit  // dlog
#endif

/// Translates a session tap into a fixed sequence of `IslandFocusSink`
/// calls. See spec §6.6 for the intent; the ordering below probes
/// `selectWorkspace` *before* `activateApp` so that a jump to a torn-down
/// workspace does not steal macOS focus unnecessarily.
@MainActor
final class IslandJumpRouter {

    private let focusSink: IslandFocusSink

    init(focusSink: IslandFocusSink) {
        self.focusSink = focusSink
    }

    /// Perform the jump. `collapseIsland()` runs exactly once whether or
    /// not intermediate steps succeed.
    ///
    /// Sequence:
    ///   1. selectWorkspace (probe) — if it returns false, workspace is
    ///      gone and we skip activation entirely (spec §6.6).
    ///   2. activateApp — explicit user focus intent.
    ///   3. focusPanel — best effort; return value ignored.
    ///   4. collapseIsland — always, exactly once.
    func jump(to session: IslandSession) {
        let workspaceFound = focusSink.selectWorkspace(id: session.workspaceId)
        guard workspaceFound else {
#if DEBUG
            dlog("island.jump failed: workspace \(session.workspaceId.uuidString.prefix(8)) not found")
#endif
            focusSink.collapseIsland()
            return
        }
        focusSink.activateApp()
        let panelFocused = focusSink.focusPanel(
            id: session.panelId,
            inWorkspace: session.workspaceId
        )
#if DEBUG
        if !panelFocused {
            dlog(
                "island.jump failed: panel \(session.panelId.uuidString.prefix(8)) not found in workspace \(session.workspaceId.uuidString.prefix(8))"
            )
        }
#endif
        focusSink.collapseIsland()
    }
}
