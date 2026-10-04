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
