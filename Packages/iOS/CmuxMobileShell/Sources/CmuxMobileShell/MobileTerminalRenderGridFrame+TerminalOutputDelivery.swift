import CMUXMobileCore
import CmuxMobileShellModel

extension MobileTerminalRenderGridFrame {
    /// True when this delta fully replaces the visible viewport without needing
    /// earlier pending deltas. A scrolling delta is never replaceable: its line
    /// feeds push rows into the consumer's local scrollback, so skipping one
    /// would silently lose history rows.
    var isReplaceableViewportPatchForMobileDelivery: Bool {
        guard !full, scrolledRows == 0 else { return false }
        let cleared = Set(clearedRows)
        guard cleared.count >= rows else { return false }
        for row in 0..<rows where !cleared.contains(row) {
            return false
        }
        return true
    }

    var mobileViewportPolicy: MobileTerminalOutputViewportPolicy {
        switch activeScreen {
        case .alternate:
            return .remoteGrid(columns: columns, rows: rows)
        case .primary:
            return .natural
        }
    }
}
