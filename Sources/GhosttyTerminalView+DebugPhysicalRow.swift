#if DEBUG

/// UI-test-only physical-row accessors. Keeping these in a DEBUG-only source
/// file prevents the harness seam from entering production builds.
extension GhosttyNSView {
    /// Reads one physical grid row's raw text, for UI tests that need to
    /// locate a hard-wrapped row without relying on the unwrapped-snapshot
    /// text used elsewhere in this file (which joins soft-wrapped rows back
    /// into one logical line).
    func debugReadPhysicalRow(_ row: Int) -> String? {
        guard let metrics = currentGridMetrics(),
              let snapshot = readPhysicalViewportSnapshot(expectedMetrics: metrics),
              row >= 0, row < snapshot.lines.count else { return nil }
        return snapshot.lines[row]
    }
}

extension GhosttySurfaceScrollView {
    func debugReadPhysicalRow(_ row: Int) -> String? {
        surfaceView.debugReadPhysicalRow(row)
    }
}

#endif
