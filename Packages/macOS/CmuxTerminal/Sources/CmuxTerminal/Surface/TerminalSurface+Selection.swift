extension TerminalSurface {
    /// Reads a bounded native selection without exposing a raw Ghostty pointer.
    ///
    /// - Parameter maxBytes: Maximum UTF-8 bytes Ghostty may materialize.
    /// - Returns: ``TerminalSurfaceSelectionRead/none`` when no selection is
    ///   active, ``TerminalSurfaceSelectionRead/selected(_:)`` for bounded text,
    ///   or ``TerminalSurfaceSelectionRead/unavailable`` when the runtime cannot
    ///   complete a bounded read.
    @MainActor
    public func readSelection(maxBytes: Int) async -> TerminalSurfaceSelectionRead {
        guard maxBytes > 0,
              let surface = liveSurfaceForGhosttyAccess(reason: "readSelection") else {
            return .unavailable
        }
        return await runtimeTeardown.readSelection(
            TerminalSurfaceRuntimeSelectionRequest(
                surface: surface,
                maxBytes: maxBytes
            )
        )
    }
}
