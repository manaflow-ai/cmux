import Foundation

extension MobileTerminalRenderGridFrame {
    /// Synthesizes a scrollback-preserving VT update for a semantic mirror.
    ///
    /// A first frame, explicit replay, geometry change, or screen switch needs
    /// a complete replacement. Steady-state full snapshots repaint only rows
    /// whose text or resolved styling changed, leaving existing history intact.
    /// This mirror-specific path intentionally differs from producer emission:
    /// it keeps DEC origin-mode updates as absolute row deltas because promoting
    /// them to full replacements would erase scrollback. Delta replay normalizes
    /// coordinate modes and always carries the current cursor, including when no
    /// rows changed.
    ///
    /// - Parameters:
    ///   - previous: The last full frame accepted by the mirror.
    ///   - forceFull: Whether the mirror's state must be rebuilt from scratch.
    /// - Returns: VT bytes that advance the mirror to this frame.
    public func semanticReplayBytes(
        comparedTo previous: MobileTerminalRenderGridFrame?,
        forceFull: Bool = false
    ) -> Data {
        guard full,
              !forceFull,
              let previous,
              previous.full,
              previous.surfaceID == surfaceID,
              previous.columns == columns,
              previous.rows == rows,
              previous.activeScreen == activeScreen else {
            return vtReplacementBytes()
        }

        let previousSignatures = previous.rowSignatures()
        let nextSignatures = rowSignatures()
        var changedRows = Set<Int>()
        for row in 0..<rows where previousSignatures[row] != nextSignatures[row] {
            changedRows.insert(row)
        }

        guard let delta = try? filteredRows(changedRows, full: false) else {
            return vtReplacementBytes()
        }
        return delta.vtPatchBytes()
    }
}
