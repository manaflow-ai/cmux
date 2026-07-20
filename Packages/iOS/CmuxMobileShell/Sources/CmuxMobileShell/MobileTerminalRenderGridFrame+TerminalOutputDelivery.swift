import CMUXMobileCore
import CmuxMobileShellModel

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

    /// Direct-grid presentation preserves the producer's rows and columns.
    /// The phone fits this grid locally and never negotiates a second PTY size.
    var mobileViewportPolicy: MobileTerminalOutputViewportPolicy {
        .remoteGrid(columns: columns, rows: rows)
    }

    /// Compatibility policy for consumers that still replay the grid as VT bytes.
    var mobileLegacyReplayViewportPolicy: MobileTerminalOutputViewportPolicy {
        switch activeScreen {
        case .alternate:
            return .remoteGrid(columns: columns, rows: rows)
        case .primary:
            return .natural
        }
    }
}
