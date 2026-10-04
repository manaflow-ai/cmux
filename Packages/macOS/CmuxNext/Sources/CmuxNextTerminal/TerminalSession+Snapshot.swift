import Foundation
import GhosttyNextKit

/// Which part of a GHOSTSNP snapshot a ``TerminalIOEvent/snapshot(_:phase:)`` holds.
public nonisolated enum TerminalSnapshotPhase: Sendable, Equatable {
    /// Envelope through READY: the renderable state.
    case ready
    /// Records after READY through FINISH (scrollback), possibly in chunks.
    case history
}

extension TerminalSession {
    /// The GHOSTSNP format version the linked libghostty restores
    /// (`ghostty_surface_snapshot_version`). A daemon IO asks the PTY owner
    /// for snapshots at this version (`terminal-snapshot-v1`); 0 means none.
    public nonisolated static var snapshotVersion: UInt16 { ghostty_surface_snapshot_version() }
}

extension TerminalSession {
    /// Restores GHOSTSNP bytes on the live surface's output lane, in stream
    /// order behind earlier output and the grid lock of the preceding
    /// `.resize` (a READY keeps that lock's generation and takes its size).
    func restoreSnapshot(_ data: Data, phase: TerminalSnapshotPhase) async {
        guard let lane = surfaceView.lane else { return }
        switch phase {
        case .ready:
            lane.restoreSnapshot(data, phase: GHOSTTY_SURFACE_SNAPSHOT_READY)
            // The restored terminal carries the owner's default palette and
            // colors (ghostty-next keeps the snapshot's colors and applies
            // only this surface's limits). This surface's config owns the
            // defaults: re-apply it once the restore ran, which keeps the
            // program's OSC overrides (`changeConfig` changes defaults only).
            await lane.drained()
            guard let surface = surfaceView.surface,
                  let config = theme?.config ?? GhosttyRuntime.shared.config else { return }
            ghostty_surface_update_config(surface, config)
        case .history:
            await lane.waitForCapacity()
            surfaceView.lane?.restoreSnapshot(data, phase: GHOSTTY_SURFACE_SNAPSHOT_HISTORY)
        }
    }
}
