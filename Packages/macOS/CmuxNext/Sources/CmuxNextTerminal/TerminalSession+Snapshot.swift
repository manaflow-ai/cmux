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
    /// The owner's Kitty image replay of the last READY's cut (S3k), applied
    /// on the surface's trusted replay path, never as PTY output.
    /// `skipped`: images the owner left out (its per-READY cap).
    case images(skipped: Int)
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

    /// The linked libghostty applies Kitty image replays
    /// (`ghostty_surface_apply_kitty_replay`, GhosttyNextKit pin).
    public nonisolated static let appliesKittyReplay = true
}
