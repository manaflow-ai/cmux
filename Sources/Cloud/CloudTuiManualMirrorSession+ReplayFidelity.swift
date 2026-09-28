import CmuxCloudTui
import CmuxTerminal
import Foundation
import os

private let replayFidelityLogger = Logger(subsystem: "com.cmuxterm.app", category: "CloudManualMirror")

/// Refetches a replacement replay that the local terminal parsed at the wrong
/// grid. See ``CloudTuiReplayFidelity`` for why growing the pane cannot repair
/// one: the daemon only replays when the remote PTY size changes.
extension CloudTuiManualMirrorSession {
    /// The grid Ghostty's terminal holds right now, or nil while a resize is
    /// still queued on its IO thread.
    func settledGrid() -> CloudTuiManualIOGrid? {
        surface?.settledGridCells().flatMap { CloudTuiManualIOGrid(columns: $0.columns, rows: $0.rows) }
    }

    func replayApplied(token: UInt64) {
        replayFidelity.replayApplied(token: token, local: settledGrid())
        scheduleFidelityCheck()
    }

    func localGridChanged(to sample: TerminalSurfaceRawSizingSample) {
        replayFidelity.localGridChanged(to: CloudTuiManualIOGrid(columns: sample.columns, rows: sample.rows))
        scheduleFidelityCheck()
    }

    /// Checks once Ghostty has applied any queued resize, so the decision
    /// reads the grid the next replay would be parsed into.
    func scheduleFidelityCheck() {
        fidelityCheckTask?.cancel()
        guard replayFidelity.mayNeedRepair else {
            fidelityCheckTask = nil
            return
        }
        fidelityCheckTask = Task { @MainActor [weak self] in
            for attempt in 0...10 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(30)) }
                guard !Task.isCancelled, let self else { return }
                if self.settledGrid() != nil || attempt == 10 {
                    self.fidelityCheckTask = nil
                    self.repairUnfaithfulReplayIfNeeded()
                    return
                }
            }
        }
    }

    /// Reattaches on a fresh connection when the pane now holds the daemon's
    /// grid but its replay was parsed at another one. The attach snapshots the
    /// VT state and subscribes atomically, so no output is lost or doubled.
    /// It runs only while nothing on the attachment is mid-flight, and its
    /// initial size equals the remote grid, so the remote PTY is not resized.
    private func repairUnfaithfulReplayIfNeeded() {
        let local = settledGrid()
        if local != nil { replayFidelity.localGridChanged(to: local) }
        guard phase == .attached,
              attachResponseReceived,
              let socketPath,
              connection != nil,
              let surface,
              surface.isRendererPortalVisible,
              surface.isNativeViewInRealWindow,
              resizeScheduler.inFlight == nil,
              !claimInFlight,
              !geometryClaimBlockedByPeer,
              let remote = lastRemoteGrid,
              resizeScheduler.desired == remote,
              !imagePaste.isBusy,
              replayFidelity.needsRepair(local: local) else { return }
        replayFidelity.repairStarted()
        replayFidelityLogger.notice("replay terminal=\(self.terminalID, privacy: .private(mask: .hash)) surface=\(self.remoteSurfaceID) decision=refetch grid=\(remote.columns)x\(remote.rows) attempt=\(self.replayFidelity.repairs)")
        tearDownConnection()
        reconnect(socketPath: socketPath)
    }
}
