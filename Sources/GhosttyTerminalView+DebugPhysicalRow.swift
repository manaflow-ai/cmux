#if DEBUG

/// UI-test-only physical-row accessors. Keeping these in a DEBUG-only source
/// file prevents the harness seam from entering production builds.
extension GhosttyNSView {
    /// Reads all physical grid rows as one coherent raw-text snapshot, for
    /// UI tests that need to locate a hard-wrapped row without issuing one
    /// renderer read per candidate row.
    func debugReadPhysicalRows() -> [String]? {
        guard let metrics = currentGridMetrics(),
              let snapshot = readPhysicalViewportSnapshot(expectedMetrics: metrics) else { return nil }
        return snapshot.lines
    }

    /// Reads one physical grid row's raw text, for UI tests that need to
    /// locate a hard-wrapped row without relying on the unwrapped-snapshot
    /// text used elsewhere in this file (which joins soft-wrapped rows back
    /// into one logical line).
    func debugReadPhysicalRow(_ row: Int) -> String? {
        guard let lines = debugReadPhysicalRows(),
              row >= 0, row < lines.count else { return nil }
        return lines[row]
    }
}

extension GhosttySurfaceScrollView {
    func debugReadPhysicalRows() -> [String]? {
        surfaceView.debugReadPhysicalRows()
    }

    func debugReadPhysicalRow(_ row: Int) -> String? {
        surfaceView.debugReadPhysicalRow(row)
    }
}


#endif
