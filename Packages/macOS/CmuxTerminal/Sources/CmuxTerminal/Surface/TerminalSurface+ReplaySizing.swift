import GhosttyKit

extension TerminalSurface {
    /// Aligns a manual-I/O surface with the grid authored by an incoming
    /// replacement replay before its VT bytes are parsed. The assigned-grid pin
    /// keeps later AppKit layout passes on the same geometry; the authoritative
    /// grid call closes the hidden-restore gap where no pixel sizing pass has
    /// established `lastUncappedPixelWidth` yet.
    @MainActor
    @discardableResult
    public func prepareForRemoteReplay(columns: Int, rows: Int) -> Bool {
        guard ioMode.usesManualIO,
              (2...Int(UInt16.max)).contains(columns),
              (2...Int(UInt16.max)).contains(rows) else { return false }
        setAssignedGrid(columns: columns, rows: rows)
        guard let runtime = liveSurfaceForGhosttyAccess(reason: "remoteReplayGrid") else { return false }
        return ghostty_surface_set_grid_size(
            runtime,
            UInt16(columns),
            UInt16(rows),
            nil
        )
    }
}
