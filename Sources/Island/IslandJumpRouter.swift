// Sources/Island/IslandJumpRouter.swift

import Foundation

/// Translates a session tap into a fixed sequence of `IslandFocusSink`
/// calls. See spec §6.6 for the required ordering.
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
            focusSink.collapseIsland()
            return
        }
        focusSink.activateApp()
        _ = focusSink.focusPanel(id: session.panelId, inWorkspace: session.workspaceId)
        focusSink.collapseIsland()
    }
}
