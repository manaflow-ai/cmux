#if os(iOS)
@testable import CmuxAgentGUIUI
import CmuxAgentGUIProjection
import CmuxAgentReplica
import Testing
import UIKit

extension TranscriptRenderingRegressionTests {
    @Test func compactSummaryAndGenericActivityInternalHeightsBothShrink() {
        let theme = AgentGUITheme(terminalTheme: .monokai)
        let rows = [Self.collapsedSummaryRow(), Self.genericActivityRow()]

        for row in rows {
            let cell = TranscriptCollectionCell(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
            Self.configureDensityCell(cell, row: row, density: .comfortable, theme: theme)
            let comfortableHeight = Self.densityFittingHeight(of: cell)
            Self.configureDensityCell(cell, row: row, density: .compact, theme: theme)
            let compactHeight = Self.densityFittingHeight(of: cell)
            Self.configureDensityCell(cell, row: row, density: .comfortable, theme: theme)
            let restoredHeight = Self.densityFittingHeight(of: cell)

            #expect(compactHeight <= comfortableHeight - 5)
            #expect(abs(restoredHeight - comfortableHeight) < 0.5)
        }
    }

    private static func configureDensityCell(
        _ cell: TranscriptCollectionCell,
        row: TranscriptRow,
        density: TranscriptDensity,
        theme: AgentGUITheme
    ) {
        cell.configure(
            row: row,
            spacing: TranscriptRowSpacing(top: 0, bottom: 0, density: density),
            theme: theme,
            answeringAskID: nil,
            failedAskID: nil,
            onShowActivity: { _ in },
            onAnswer: { _, _ in },
            onShowTerminal: {}
        )
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        cell.contentView.layoutIfNeeded()
    }

    private static func densityFittingHeight(of cell: TranscriptCollectionCell) -> CGFloat {
        cell.rowLayoutResult?.height ?? 0
    }

    private static func collapsedSummaryRow() -> TranscriptRow {
        let journal = JournalID(rawValue: "density-summary")
        let turnID = TranscriptTurnID(
            journalID: journal,
            promptSeq: EntrySeq(rawValue: 1),
            segmentAnchorSeq: EntrySeq(rawValue: 1)
        )
        return TranscriptRow(
            rowID: .activitySummary(turnID),
            rowKind: .activitySummary(TranscriptActivitySummary(
                editedFileCount: 1,
                readFileCount: 0,
                searchedCode: false,
                listedFiles: false,
                commandCount: 1,
                eventCount: 0,
                items: []
            )),
            turnID: turnID
        )
    }

    private static func genericActivityRow() -> TranscriptRow {
        let journal = JournalID(rawValue: "density-generic")
        return TranscriptRow(
            rowID: .entry(journalID: journal, seq: EntrySeq(rawValue: 1)),
            rowKind: .genericActivity(TranscriptGenericActivity(
                kindLabel: "future_kind",
                summary: "A future activity"
            ))
        )
    }
}
#endif
