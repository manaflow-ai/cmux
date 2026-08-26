#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import Testing
import UIKit

@testable import CmuxMobileTerminal

@MainActor
@Suite("Verified replay geometry fit", .serialized)
struct VerifiedReplayGeometryFitTests {
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

    @Test("verified replay fits a one-row effective-grid difference exactly")
    func verifiedReplayFitsOneRowDifferenceExactly() async throws {
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
            guard let rendered = snapshot.renderedSize,
                  let reported = snapshot.reportedSize else {
                return false
            }
            return snapshot.renderRect.width > 0
                && rendered.columns == reported.columns
                && rendered.rows == reported.rows
                && rendered.columns > 1
                && rendered.rows > 1
        }
        let natural = try #require(view.debugGeometrySnapshotForTesting().renderedSize)
        #expect(mounted)

        view.verifiedReplayRenderSuppressed = true
        let targetRows = natural.rows - 1
        let applied = await view.applyViewSizeAndWait(
            cols: natural.columns,
            rows: targetRows
        )
        let rendered = try #require(view.debugGeometrySnapshotForTesting().renderedSize)

        #expect(applied)
        #expect(rendered.columns == natural.columns)
        #expect(rendered.rows == targetRows)
    }

    @Test("verified replay waits for a larger grid to fit, then resolves it exactly")
    func verifiedReplayFitsOneColumnLargerAfterViewportGrowth() async throws {
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
            guard let rendered = snapshot.renderedSize,
                  let reported = snapshot.reportedSize else {
                return false
            }
            return snapshot.renderRect.width > 0
                && rendered.columns == reported.columns
                && rendered.rows == reported.rows
                && rendered.columns > 1
        }
        let naturalSnapshot = view.debugGeometrySnapshotForTesting()
        let natural = try #require(naturalSnapshot.renderedSize)
        #expect(mounted)

        view.verifiedReplayRenderSuppressed = true
        let targetColumns = natural.columns + 1
        let appliedBeforeGrowth = await view.applyViewSizeAndWait(
            cols: targetColumns,
            rows: natural.rows
        )
        let beforeGrowth = try #require(view.debugGeometrySnapshotForTesting().renderedSize)

        #expect(appliedBeforeGrowth && beforeGrowth.columns == natural.columns)

        growViewportByOneColumn(
            view: view,
            window: window,
            snapshot: naturalSnapshot,
            columns: natural.columns
        )

        let resolved = await waitUntil(timeout: .seconds(5)) {
            view.debugGeometrySnapshotForTesting().renderedSize?.columns == targetColumns
        }
        let afterGrowth = try #require(view.debugGeometrySnapshotForTesting().renderedSize)

        #expect(resolved && afterGrowth.columns == targetColumns)
    }

    private func growViewportByOneColumn(
        view: GhosttySurfaceView,
        window: UIWindow,
        snapshot: GhosttySurfaceView.DebugGeometrySnapshot,
        columns: Int
    ) {
        let cellWidth = snapshot.renderRect.width / CGFloat(columns)
        window.frame.size.width += cellWidth + 1
        view.frame = window.bounds
        view.setNeedsLayout()
        view.layoutIfNeeded()
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
