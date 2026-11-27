import CmuxTerminal
import Foundation

extension CloudTuiManualMirrorSession {
    /// Applies an attach replay that arrived before the native pane was bound.
    /// The replay is already reset and color-composed, so it must enter Ghostty
    /// exactly once after binding.
    func flushPendingReplay() {
        guard let pendingReplay, let surface else { return }
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
