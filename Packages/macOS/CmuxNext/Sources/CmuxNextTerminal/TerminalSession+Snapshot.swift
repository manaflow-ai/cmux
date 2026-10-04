public import Foundation
import GhosttyNextKit

/// Which part of a GHOSTSNP snapshot a ``TerminalIOEvent/snapshot(_:phase:)`` holds.
public nonisolated enum TerminalSnapshotPhase: Sendable, Equatable {
    /// Envelope through READY: the renderable state.
    case ready
    /// Records after READY through FINISH (scrollback), possibly in chunks.
    case history
    /// A READY cut exactly at the owner's resize: the surface reflows and
    /// keeps its own history when it matches the owner's check (S2c).
    case readyLocalHistory(TerminalLocalHistory)
}

/// The owner's grid and history check of a local-history READY.
public nonisolated struct TerminalLocalHistory: Sendable, Equatable {
    public var columns: Int
    public var rows: Int
    /// The owner's primary-screen history rows at the cut.
    public var historyRows: UInt64
    /// libghostty's history digest of the owner's newest history rows.
    public var digest: Data

    public init(columns: Int, rows: Int, historyRows: UInt64, digest: Data) {
        self.columns = columns
        self.rows = rows
        self.historyRows = historyRows
        self.digest = digest
    }
}

extension TerminalSession {
    /// The GHOSTSNP format version the linked libghostty restores
    /// (`ghostty_surface_snapshot_version`). A daemon IO asks the PTY owner
    /// for snapshots at this version (`terminal-snapshot-v1`); 0 means none.
    public nonisolated static var snapshotVersion: UInt16 { ghostty_surface_snapshot_version() }

    /// The linked libghostty restores local-history READYs
    /// (`ghostty_surface_restore_snapshot_local_history`, GhosttyNextKit pin).
    public nonisolated static let restoresLocalHistory = true
}

extension TerminalSession {
    /// Restores GHOSTSNP bytes on the live surface's output lane, in stream
    /// order behind earlier output and the grid lock of the preceding
    /// `.resize` (a READY keeps that lock's generation and takes its size).
    /// Returns whether a READY restored (history: whether it was queued).
    @discardableResult
    func restoreSnapshot(_ data: Data, phase: TerminalSnapshotPhase) async -> Bool {
        guard let lane = surfaceView.lane else { return false }
        switch phase {
        case .ready:
            // ghostty-next applies this surface's palette, default colors and
            // cursor defaults to the restored terminal itself (local policy,
            // GhosttyNextKit 68ac618db), keeping the program's overrides.
            lane.restoreSnapshot(data, phase: GHOSTTY_SURFACE_SNAPSHOT_READY)
            await lane.drained()
            return lane.lastReadyRestored
        case .history:
            await lane.waitForCapacity()
            surfaceView.lane?.restoreSnapshot(data, phase: GHOSTTY_SURFACE_SNAPSHOT_HISTORY)
            return true
        case .readyLocalHistory(let local):
            return await restoreLocalHistory(data, local, on: lane)
        }
    }

    /// The local-history READY: the surface's grid record follows the
    /// restore (no set_grid: the restore reflows the old grid itself). On a
    /// mismatch the READY is restored without history and the IO asks for a
    /// fresh READY + history; on an error the IO asks as well.
    private func restoreLocalHistory(_ data: Data, _ local: TerminalLocalHistory, on lane: TerminalOutputLane) async -> Bool {
        lane.restoreLocalHistory(data, expectedRows: local.historyRows, digest: local.digest)
        surfaceView.applyAnnouncedGrid(TerminalGridSize(columns: local.columns, rows: local.rows), restored: true)
        await lane.drained()
        let result = lane.lastLocalHistoryResult
        guard result == Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_RESTORED.rawValue) else {
            noteLocalHistoryMismatch()
            return result == Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_MISMATCH.rawValue)
        }
        return true
    }
}
