import CMUXMobileCore
import Foundation

// Render-grid frame builder shared by the stale-floor and replay tests. The
// wire-format event builders (renderGridEventFrame, terminalBytesEventFrame,
// emptyRenderGridEventFrame) live in MobileShellRenderGridEventFrameFixtures.

func renderGridFrame(
    surfaceID: String,
    seq: UInt64,
    text: String,
    columns: Int = 80,
    rows: Int = 4,
    activeScreen: MobileTerminalRenderGridFrame.Screen = .primary,
    full: Bool = true,
    anchor: MobileTerminalRenderGridFrame.Anchor = .viewport,
    historyRows: UInt64? = nil,
    deltaBaseHistoryRows: UInt64? = nil
) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: seq,
        columns: columns,
        rows: rows,
        full: full,
        rowSpans: [
            MobileTerminalRenderGridFrame.RowSpan(
                row: 0,
                column: 0,
                styleID: 0,
                text: text
            ),
        ],
        activeScreen: activeScreen,
        anchor: anchor,
        historyRows: historyRows,
        deltaBaseHistoryRows: deltaBaseHistoryRows
    )
}
