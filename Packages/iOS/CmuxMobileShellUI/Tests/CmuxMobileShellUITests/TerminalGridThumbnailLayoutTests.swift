import CMUXMobileCore
import CoreGraphics
import Testing
@testable import CmuxMobileShell
@testable import CmuxMobileShellUI

@Suite struct TerminalGridThumbnailLayoutTests {
    @Test func gridRowsAndColumnsMapToCanvasCoordinates() throws {
        let snapshot = try snapshot(
            columns: 4,
            rows: 2,
            spans: [.init(row: 1, column: 2, text: "ok")]
        )

        let layout = TerminalGridThumbnailLayout(snapshot: snapshot)
        let run = try #require(layout.runs(in: CGSize(width: 80, height: 40)).first)
        #expect(run.frame == CGRect(x: 40, y: 20, width: 40, height: 20))
    }

    @Test func alternateScreenIdentitySurvivesThumbnailLayout() throws {
        let snapshot = try snapshot(
            columns: 8,
            rows: 3,
            activeScreen: .alternate,
            spans: [.init(row: 0, column: 0, text: "htop")]
        )

        #expect(TerminalGridThumbnailLayout(snapshot: snapshot).activeScreen == .alternate)
    }

    @Test func wideGlyphCellWidthPinsFollowingRunToItsProducerColumn() throws {
        let snapshot = try snapshot(
            columns: 4,
            rows: 1,
            spans: [
                .init(row: 0, column: 0, text: "界", cellWidth: 2),
                .init(row: 0, column: 2, text: "x", cellWidth: 1),
            ]
        )

        let runs = TerminalGridThumbnailLayout(snapshot: snapshot)
            .runs(in: CGSize(width: 40, height: 10))
        #expect(runs.map(\.frame.minX) == [0, 20])
        #expect(runs.map(\.frame.width) == [20, 10])
    }

    private func snapshot(
        columns: Int,
        rows: Int,
        activeScreen: MobileTerminalRenderGridFrame.Screen = .primary,
        spans: [MobileTerminalRenderGridFrame.RowSpan]
    ) throws -> PreviewGridSnapshot {
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "surface",
            stateSeq: 1,
            columns: columns,
            rows: rows,
            rowSpans: spans,
            activeScreen: activeScreen
        )
        var accumulator = PreviewGridAccumulator()
        guard case .applied(let snapshot) = accumulator.apply(frame) else {
            Issue.record("full frame did not establish a preview baseline")
            return .awaitingBaseline(surfaceID: "surface")
        }
        return snapshot
    }
}
