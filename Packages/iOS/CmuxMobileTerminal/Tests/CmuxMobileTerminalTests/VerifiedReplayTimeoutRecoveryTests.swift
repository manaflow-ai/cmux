#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import QuartzCore
import Testing
import UIKit

@testable import CmuxMobileTerminal

@MainActor
@Suite("Verified replay timeout recovery", .serialized)
struct VerifiedReplayTimeoutRecoveryTests {
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

    @Test("timeout clears the frozen presentation before rebuilding the renderer")
    func timeoutClearsFrozenPresentation() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        defer {
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }

        let surface = try #require(view.surface)
        let frozenLayer = CALayer()
        view.layer.addSublayer(frozenLayer)
        view.verifiedReplayFrozenPresentationLayer = frozenLayer
        view.verifiedReplayRenderSuppressed = true

        let waiter = Task { @MainActor in
            await withCheckedContinuation { continuation in
                view.pendingVerifiedReplayPresentation = PendingVerifiedReplayPresentation(
                    id: 7,
                    startedAt: CACurrentMediaTime() - GhosttySurfaceView.outputApplyTimeout,
                    surface: surface,
                    generation: view.surfaceGeneration,
                    read: nil,
                    fence: VerifiedReplayPresentationFence(
                        expectedToken: 7,
                        expectedGeometryRevision: 1,
                        expectedGeometry: VerifiedReplayPresentationGeometry(
                            rendererFrame: view.bounds,
                            rendererBounds: view.bounds,
                            rendererPosition: CGPoint(x: view.bounds.midX, y: view.bounds.midY),
                            rendererAnchorPoint: CGPoint(x: 0.5, y: 0.5),
                            rendererContentsScale: 3,
                            rendererTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                            hostBounds: view.bounds,
                            hostPosition: CGPoint(x: view.bounds.midX, y: view.bounds.midY),
                            hostAnchorPoint: CGPoint(x: 0.5, y: 0.5),
                            hostTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                            viewportRect: view.bounds
                        )
                    ),
                    observedFrame: nil,
                    continuation: continuation
                )
            }
        }

        await Task.yield()
        #expect(view.pendingVerifiedReplayPresentation != nil)
        #expect(view.checkSurfaceOperationDeadlines(now: CACurrentMediaTime()))
        #expect(await waiter.value == nil)
        #expect(view.verifiedReplayFrozenPresentationLayer == nil)
        #expect(!view.verifiedReplayRenderSuppressed)
        #expect(frozenLayer.superlayer == nil)
    }
}
#endif
