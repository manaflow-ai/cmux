import AppKit
@testable import CmuxNextLayout
import Testing

/// Divider hit areas may cover a Chromium page, so only a line that currently
/// draws pixels may be reported as an occlusion rect. A column edge that parts
/// nothing (the strip's last) stays transparent at rest, and one between two
/// columns draws the split's line; row edges use a quiet separator and become
/// prominent on hover or drag.
@MainActor
struct DividerHandleLineTests {
    @Test func edgeHandlesDoNotReserveAnOcclusionHoleAtRest() {
        let edge = DividerHandleView(kind: .columnEdge(ColumnID("column")), axis: .horizontal)
        edge.showsIdleLine = false

        #expect(!edge.isLineVisible)

        edge.setHovered(true)
        #expect(edge.isLineVisible)
    }

    @Test func aColumnEdgeBetweenColumnsDrawsTheSplitsLineAtRest() {
        let edge = DividerHandleView(kind: .columnEdge(ColumnID("column")), axis: .horizontal)
        edge.showsIdleLine = true
        #expect(edge.isLineVisible)
    }

    @Test func splitHandlesKeepTheirIdleSeparatorVisible() {
        let split = DividerHandleView(kind: .split(SplitID("split")), axis: .horizontal)

        #expect(split.isLineVisible)

        split.showsIdleLine = false
        #expect(!split.isLineVisible)
        split.setHovered(true)
        #expect(split.isLineVisible)
    }

    @Test func rowEdgesUseAQuietIdleSeparatorAndCanOptOut() {
        let row = DividerHandleView(kind: .rowEdge(ColumnID("column"), RowID("upper")), axis: .vertical)

        #expect(row.isLineVisible)

        row.showsIdleLine = false
        #expect(!row.isLineVisible)
        row.setHovered(true)
        #expect(row.isLineVisible)
    }

    @Test func rowSeparatorFollowsThePaneSeparationOptOut() {
        var style = LayoutStyle()
        #expect(style.showsRowSeparator)

        style.paneSeparation = .none
        #expect(!style.showsRowSeparator)

        style.paneSeparation = .dividers
        style.drawsLines = false
        #expect(!style.showsRowSeparator)
    }
}
