#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

@MainActor
@Suite("Ghostty semantic scene interactions", .serialized)
struct GhosttySemanticSceneInteractionTests {
    @Test
    func displayFramesRetryViewportReportsAndFlushRemoteScroll() throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = SemanticSceneInteractionDelegate()
        let view = GhosttySurfaceView(
            runtime: runtime,
            delegate: delegate,
            renderingMode: .semanticScene
        )
        defer { view.prepareForDismantle() }
        view.stopDisplayLink()
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.stopDisplayLink()

        view.applySemanticSceneMetrics(GhosttySemanticSceneMetrics(
            columns: 80,
            rows: 24,
            pixelWidth: 1_170,
            pixelHeight: 756,
            cellWidth: 14,
            cellHeight: 28,
            paddingTop: 60,
            paddingRight: 20,
            paddingBottom: 24,
            paddingLeft: 30
        ))
        #expect(delegate.resizeReports.count == 1)

        view.retryViewportReport()
        for _ in 0 ..< 16 {
            view.handleDisplayLinkFire()
        }
        #expect(delegate.resizeReports.count == 2)
        #expect(delegate.resizeReports.last?.size.columns == 80)
        #expect(delegate.resizeReports.last?.size.rows == 24)

        let drawableRect = view.semanticScenePresentationLayer.frame
        let touchPoint = CGPoint(
            x: drawableRect.minX
                + (30 + 2.5 * 14) * drawableRect.width / 1_170,
            y: drawableRect.minY
                + (60 + 1.5 * 28) * drawableRect.height / 756
        )
        view.debugEnqueueScrollMechanicsDelta(
            84,
            touchPoint: touchPoint
        )
        view.handleDisplayLinkFire()

        let scrollReport = try #require(delegate.scrollReports.first)
        #expect(delegate.scrollReports.count == 1)
        #expect(scrollReport.lines != 0)
        #expect(scrollReport.column == 2)
        #expect(scrollReport.row == 1)
    }
}

@MainActor
private final class SemanticSceneInteractionDelegate:
    GhosttySurfaceViewDelegate {
    struct ResizeReport {
        let size: TerminalGridSize
        let reportID: UInt64
    }

    struct ScrollReport {
        let lines: Double
        let column: Int
        let row: Int
    }

    var resizeReports: [ResizeReport] = []
    var scrollReports: [ScrollReport] = []

    func ghosttySurfaceView(
        _: GhosttySurfaceView,
        didProduceInput _: Data
    ) {}

    func ghosttySurfaceView(
        _: GhosttySurfaceView,
        didResize size: TerminalGridSize,
        reportID: UInt64
    ) {
        resizeReports.append(ResizeReport(size: size, reportID: reportID))
    }

    func ghosttySurfaceView(
        _: GhosttySurfaceView,
        didScrollLines lines: Double,
        atCol column: Int,
        row: Int
    ) {
        scrollReports.append(ScrollReport(
            lines: lines,
            column: column,
            row: row
        ))
    }
}
#endif
