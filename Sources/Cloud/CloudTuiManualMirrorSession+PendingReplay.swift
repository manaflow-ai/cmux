import CmuxTerminal
import Foundation

extension CloudTuiManualMirrorSession {
    /// Applies an attach replay that arrived before the native pane was bound.
    /// The replay is already reset and color-composed, so it must enter Ghostty
    /// exactly once after binding.
    func flushPendingReplay() {
        guard let surface else { return }
        // The replay addresses the daemon's grid. Pin the newly bound surface
        // to it before parsing, as `applyReplacement` does for a bound one;
        // pinning later would resize the parsed prompt (#16184).
        if let lastRemoteGrid {
            surface.setAssignedGrid(columns: lastRemoteGrid.columns, rows: lastRemoteGrid.rows)
        }
        guard let pendingReplay else { return }
        self.pendingReplay = nil
        let token = replayFidelity.replayQueued(remote: lastRemoteGrid, local: settledGrid())
        surface.processRemoteReplay(pendingReplay) { [weak self, weak surface] in
            surface?.forceRefresh(reason: "cloud.replay.applied")
            self?.replayApplied(token: token)
        } onDiscarded: { [weak self] in
            self?.replayDiscarded(token: token)
        }
    }
}
