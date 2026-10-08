#if DEBUG
import CmuxTerminal

extension AppDelegate {
    /// Captures native surface identity and pending input at a power boundary.
    /// This is opt-in evidence for the long-lived PTY input incident; it does
    /// not attempt to recover a surface.
    func logTerminalPowerRuntimeState(source: String) {
        let states = GhosttyApp.terminalSurfaceRegistry
            .allTerminalSurfacesUnordered()
            .map { surface in
                let pending = surface.debugPendingSocketInputForTesting()
                return "surface=\(surface.id.uuidString.prefix(8)) " +
                    "pointer=\(String(describing: surface.surface)) " +
                    "generation=\(surface.runtimeSurfaceGeneration) " +
                    "live=\(surface.hasLiveSurface ? 1 : 0) " +
                    "pendingItems=\(pending.items) pendingBytes=\(pending.bytes)"
            }
            .joined(separator: " | ")
        cmuxDebugLog(
            "systemPower.runtimeState source=\(source) " +
            "surfaceCount=\(GhosttyApp.terminalSurfaceRegistry.allSurfaces().count) " +
            (states.isEmpty ? "surfaces=none" : states)
        )
    }
}
#endif
