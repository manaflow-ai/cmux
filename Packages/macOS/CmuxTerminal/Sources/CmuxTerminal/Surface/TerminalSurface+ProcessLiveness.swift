public import GhosttyKit

public extension TerminalSurface {
    /// Reports whether this surface's locally spawned process is alive.
    ///
    /// Returns `nil` for manual-I/O surfaces and whenever no validated live
    /// Ghostty runtime surface is available.
    @MainActor
    func processAlive() -> Bool? {
        guard !manualIO,
              let liveSurface = validatedRuntimeSurfaceForObservation() else {
            return nil
        }
        return !ghostty_surface_process_exited(liveSurface)
    }
}
