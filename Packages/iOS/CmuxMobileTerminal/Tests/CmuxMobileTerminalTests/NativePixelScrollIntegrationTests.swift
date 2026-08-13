#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import Testing
import UIKit

@testable import CmuxMobileTerminal

@MainActor
@Suite("Native pixel scroll integration", .serialized)
struct NativePixelScrollIntegrationTests {
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

    @Test("production scroll mechanics move only the renderer between rows")
    func productionScrollMechanicsMoveRendererBetweenRows() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        view.scrollPresentationAuthority = .localPixelViewport

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
        defer {
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }

        let rendererReady = await waitUntil(timeout: .seconds(5)) {
            view.localScrollbackRendererBaseFrame != nil
                && (view.layer.sublayers ?? []).contains(where: view.isGhosttyRendererLayer)
        }
        #expect(rendererReady)

        // Mounting the real Ghostty surface publishes its initial scrollbar
        // asynchronously. Let that startup event settle before replacing it
        // with the deterministic scrollback geometry exercised below.
        let startupBoundaryReady = await waitUntil(timeout: .seconds(5)) {
            view.nativePixelScrollBoundary != nil
        }
        #expect(startupBoundaryReady)

        let cellHeight = view.renderedCellSizeInPoints.height
        #expect(cellHeight > 1)
        let boundary = TerminalScrollBoundary(
            totalRows: 120,
            viewportOffsetRows: 60,
            visibleRows: 40
        )
        view.handleScrollBoundaryChange(boundary)

        let mechanicsView = try #require(
            view.subviews.compactMap { $0 as? UIScrollView }.first
        )
        let expectedMaximumOffset = CGFloat(80) * cellHeight
        #expect(
            abs(
                mechanicsView.contentSize.height
                    - mechanicsView.bounds.height
                    - expectedMaximumOffset
            ) < 0.5
        )

        let halfRowOffset = CGFloat(boundary.viewportOffsetRows) * cellHeight - cellHeight / 2
        mechanicsView.setContentOffset(CGPoint(x: 0, y: halfRowOffset), animated: false)

        let baseFrame = try #require(view.localScrollbackRendererBaseFrame)
        let rendererLayer = try #require(
            (view.layer.sublayers ?? []).first(where: view.isGhosttyRendererLayer)
        )
        let appliedTranslation = rendererLayer.frame.minY - baseFrame.minY

        #expect(abs(appliedTranslation - cellHeight / 2) < 0.5)
        #expect(view.transform == .identity)
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
