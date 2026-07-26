#if canImport(UIKit)
import CMUXMobileCore
import GhosttyKit
import Testing
import UIKit

@testable import CmuxMobileTerminal

@Suite("Ghostty runtime actions")
struct GhosttyRuntimeActionTests {
    @MainActor
    @Test("renderer continuation actions request another frame")
    func rendererContinuationActionRequestsAnotherFrame() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = RendererContinuationTestDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        controller.view.addSubview(view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            view.prepareForDismantle()
            window.isHidden = true
        }

        let surface = try #require(view.surface)
        view.needsDraw = false
        #expect(
            GhosttyRuntime.simulateSurfaceActionForTesting(
                surface: surface,
                tag: GHOSTTY_ACTION_RENDER
            )
        )
        for _ in 0..<10 where !view.needsDraw {
            await Task.yield()
        }
        #expect(view.needsDraw)
    }

    @MainActor
    @Test("stale renderer continuations do not follow reused surface addresses")
    func staleRendererContinuationDoesNotTargetReplacementView() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = RendererContinuationTestDelegate()
        let sourceView = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        let replacementView = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        controller.view.addSubview(sourceView)
        controller.view.addSubview(replacementView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            sourceView.prepareForDismantle()
            replacementView.prepareForDismantle()
            window.isHidden = true
        }

        let sourceSurface = try #require(sourceView.surface)
        let bridge = try #require(
            GhosttySurfaceBridge.fromOpaque(ghostty_surface_userdata(sourceSurface))
        )
        let pendingDelivery = bridge.scheduleRenderWakeup()

        // Model the source surface being detached and its raw address being
        // reused before the queued MainActor continuation gets a turn.
        bridge.detach()
        GhosttySurfaceView.register(surface: sourceSurface, for: replacementView)

        #expect(GhosttySurfaceView.view(for: sourceSurface) === replacementView)
        #expect(await pendingDelivery.value == false)
    }

    @MainActor
    @Test("a detached callback bridge does not own the terminal view")
    func detachedCallbackBridgeDoesNotOwnTerminalView() throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = RendererContinuationTestDelegate()
        var view: GhosttySurfaceView? = GhosttySurfaceView(runtime: runtime, delegate: delegate)
        _ = try #require(view?.surface)
        let bridge = try #require(view?.bridge)

        bridge.detach()
        #expect(isKnownUniquelyReferenced(&view))
        view?.prepareForDismantle()
        view = nil
        withExtendedLifetime(bridge) {}
    }
}

@MainActor
private final class RendererContinuationTestDelegate: GhosttySurfaceViewDelegate {
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
#endif
