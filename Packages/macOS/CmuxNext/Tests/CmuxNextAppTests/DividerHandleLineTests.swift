import AppKit
@testable import CmuxNextLayout
import Testing

/// Divider hit areas may cover a Chromium page, so only a line that currently
/// draws pixels may be reported as an occlusion rect. Column and row edges are
/// transparent at rest and become visible on hover or drag.
@MainActor
struct DividerHandleLineTests {
    @Test func edgeHandlesDoNotReserveAnOcclusionHoleAtRest() {
        let edge = DividerHandleView(kind: .columnEdge(ColumnID("column")), axis: .horizontal)

        #expect(!edge.isLineVisible)

        edge.setHovered(true)
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
}
