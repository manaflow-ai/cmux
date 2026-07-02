import CMUXMobileCore
import Foundation

// Render-grid frame builder shared by the stale-floor and replay tests. The
// wire-format event builders (renderGridEventFrame, terminalBytesEventFrame,
// emptyRenderGridEventFrame) live in MobileShellRenderGridEventFrameFixtures.

func renderGridFrame(
    surfaceID: String,
    seq: UInt64,
    text: String,
    activeScreen: MobileTerminalRenderGridFrame.Screen = .primary,
    full: Bool = true
) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: seq,
        columns: 16,
        rows: 4,
        full: full,
        rowSpans: [
            MobileTerminalRenderGridFrame.RowSpan(
                row: 0,
                column: 0,
                styleID: 0,
                text: text
            ),
        ],
        activeScreen: activeScreen
    )
}
