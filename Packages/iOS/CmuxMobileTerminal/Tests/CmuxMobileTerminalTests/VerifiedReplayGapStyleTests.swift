#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import Testing
import UIKit

@testable import CmuxMobileTerminal

@MainActor
@Suite("Verified replay gap styling", .serialized)
struct VerifiedReplayGapStyleTests {
    private final class Delegate: NSObject, GhosttySurfaceViewDelegate {
        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didProduceInput data: Data
        ) {}

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didResize size: TerminalGridSize,
            reportID: UInt64
        ) {}
    }

    @Test("full replay leaves an omitted gap in the default style")
    func fullReplayPreservesDefaultStyledGap() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
        defer {
            view.verifiedReplayRenderSuppressed = false
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }

        let mounted = await waitUntil(timeout: .seconds(5)) {
            let snapshot = view.debugGeometrySnapshotForTesting()
            return snapshot.renderRect.width > 0
                && snapshot.renderedSize?.columns ?? 0 > 24
                && snapshot.renderedSize?.rows ?? 0 > 1
        }
        #expect(mounted)
        let size = try #require(view.debugGeometrySnapshotForTesting().renderedSize)
        let frame = try makeFrame(size: size, terminalConfigTheme: view.terminalConfigTheme)

        #expect(await view.freezeVerifiedReplayPresentation(transactionID: 1))
        #expect(await view.applyViewSizeAndWait(cols: size.columns, rows: size.rows))
        #expect(await view.processOutputAndWait(
            frame.vtReplacementBytes(),
            terminalConfigTheme: frame.terminalConfigTheme
        ))
        let observed = await view.presentVerifiedReplayAndReadBack(
            frame: frame,
            configuredCursorColor: frame.terminalConfigTheme?.cursor
        )

        let expectedSnapshot = try #require(MobileTerminalRenderGridVisualSnapshot(fullFrame: frame))
        let observedFrame = try #require(observed)
        let observedSnapshot = try #require(MobileTerminalRenderGridVisualSnapshot(fullFrame: observedFrame))
        #expect(observedSnapshot == expectedSnapshot)
    }

    private func makeFrame(
        size: TerminalGridSize,
        terminalConfigTheme: TerminalTheme
    ) throws -> MobileTerminalRenderGridFrame {
        return try MobileTerminalRenderGridFrame(
            surfaceID: "gap-style",
            stateSeq: 1,
            renderEpoch: "gap-style-epoch",
            renderRevision: 1,
            columns: size.columns,
            rows: size.rows,
            cursor: .init(row: 0, column: 21),
            styles: [
                .init(
                    id: 0,
                    foreground: terminalConfigTheme.foreground,
                    background: terminalConfigTheme.background
                ),
                .init(id: 1, foreground: "#5FD700", background: "#585858"),
                .init(id: 2, foreground: "#585858", background: "#1E1E1E"),
                .init(id: 3, foreground: "#FFFFFF", background: "#585858")
            ],
            rowSpans: [
                .init(row: 0, column: 0, styleID: 1, text: "left ", cellWidth: 5),
                .init(row: 0, column: 5, styleID: 2, text: "", cellWidth: 1),
                .init(row: 0, column: 6, styleID: 3, text: " ", cellWidth: 1),
                .init(row: 0, column: 20, styleID: 2, text: "", cellWidth: 1)
            ],
            terminalConfigTheme: terminalConfigTheme
        )
    }

    private func waitUntil(
        timeout: Duration,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if predicate() { return true }
            do {
                try await clock.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
        return predicate()
    }
}
#endif
