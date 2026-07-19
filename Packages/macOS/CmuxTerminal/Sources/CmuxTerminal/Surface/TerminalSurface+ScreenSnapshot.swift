extension TerminalSurface {
    /// Reads plain rendered text from the newest active-screen rows.
    ///
    /// This deliberately excludes scrollback and terminal styling. Consumers
    /// receive Ghostty's cell-model text rather than a VT serialization, so row
    /// boundaries and control sequences cannot affect semantic matching.
    @MainActor
    public func boundedActiveScreenTailText(maxRows: Int, maxBytes: Int) async -> String? {
        guard maxRows > 0,
              maxBytes > 0,
              let totalRows = rawSizingSample()?.rows,
              totalRows > 0,
              let surface = liveSurfaceForGhosttyAccess(reason: "boundedActiveScreenTailText"),
              let startRow = UInt32(exactly: max(0, totalRows - min(totalRows, maxRows))) else {
            return nil
        }
        return await runtimeTeardown.readActiveScreenTailText(
            TerminalSurfaceRuntimeVisibleTextRequest(
                surface: surface,
                startRow: startRow,
                maxBytes: maxBytes
            )
        )
    }

    /// Reads a byte-bounded VT reconstruction of the newest physical terminal rows.
    ///
    /// Ghostty selects the history suffix and formats it into a fixed-size buffer
    /// before any bytes cross into Swift. The result therefore preserves rendered
    /// styles, conceal, wide characters, and graphemes without exposing raw PTY
    /// output or requiring a render-grid JSON snapshot.
    ///
    /// - Parameters:
    ///   - maxRows: Maximum number of physical history/current-screen rows to include.
    ///   - maxBytes: Hard maximum for the formatted VT byte buffer.
    /// - Returns: A complete UTF-8 VT reconstruction, or `nil` when no bounded snapshot is available.
    @MainActor
    public func boundedScreenTailVT(maxRows: Int, maxBytes: Int) async -> String? {
        guard maxRows > 0,
              maxBytes > 0,
              let surface = liveSurfaceForGhosttyAccess(reason: "boundedScreenTailVT") else {
            return nil
        }
        return await runtimeTeardown.readScreenTailVT(
            TerminalSurfaceRuntimeScreenTailRequest(
                surface: surface,
                maxRows: maxRows,
                maxBytes: maxBytes
            )
        )
    }
}
