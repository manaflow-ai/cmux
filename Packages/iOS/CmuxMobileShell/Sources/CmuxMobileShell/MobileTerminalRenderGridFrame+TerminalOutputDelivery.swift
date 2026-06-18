import CMUXMobileCore

extension MobileTerminalRenderGridFrame {
    /// True when this delta fully replaces the visible viewport without needing
    /// earlier pending deltas.
    var isReplaceableViewportPatchForMobileDelivery: Bool {
        guard !full else { return false }
        let cleared = Set(clearedRows)
        guard cleared.count >= rows else { return false }
        for row in 0..<rows where !cleared.contains(row) {
            return false
        }
        return true
    }
}
