import GhosttyKit

extension TerminalSurface {
    /// Aligns a manual-I/O surface with the grid authored by an incoming
    /// replacement replay before its VT bytes are parsed. This is a transient
    /// parser/renderer fence: the next real pane-geometry pass can return to
    /// the local desired grid and negotiate that size with the remote PTY.
    @MainActor
    @discardableResult
    public func prepareForRemoteReplay(columns: Int, rows: Int) -> Bool {
        guard ioMode.usesManualIO,
              (2...Int(UInt16.max)).contains(columns),
              (2...Int(UInt16.max)).contains(rows) else { return false }
        guard let runtime = liveSurfaceForGhosttyAccess(reason: "remoteReplayGrid") else { return false }
        return ghostty_surface_set_grid_size(
            runtime,
            UInt16(columns),
            UInt16(rows),
            nil
        )
    }
}
