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
        // Count wakeup draws: the view's own layout also sets `needsDraw`, so
        // that flag would pass without the render action being delivered.
        var wakeupDraws = 0
        view.onDrawForWakeupForTesting = { wakeupDraws += 1 }
        #expect(
            GhosttyRuntime.simulateSurfaceActionForTesting(
                surface: surface,
                tag: GHOSTTY_ACTION_RENDER
            )
        )
        for _ in 0..<10 where wakeupDraws == 0 {
            await Task.yield()
        }
        #expect(wakeupDraws > 0)
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
        // `needsDraw` alone cannot prove the stale continuation missed: the
        // replacement's own first layout and its off-main geometry result also
        // set it on later main-actor turns. Count wakeup draws instead, and
        // detach the replacement's own bridge so only a continuation that
        // resolves the view by surface address could reach it.
        let replacementSurface = try #require(replacementView.surface)
        GhosttySurfaceBridge.fromOpaque(ghostty_surface_userdata(replacementSurface))?.detach()
        var replacementWakeupDraws = 0
        replacementView.onDrawForWakeupForTesting = { replacementWakeupDraws += 1 }

        #expect(
            GhosttyRuntime.simulateSurfaceActionForTesting(
                surface: sourceSurface,
                tag: GHOSTTY_ACTION_RENDER
            )
        )

        // Model the source surface being detached and its raw address being
        // reused before the queued MainActor continuation gets a turn.
        bridge.detach()
        GhosttySurfaceView.register(surface: sourceSurface, for: replacementView)

        for _ in 0..<10 where replacementWakeupDraws == 0 {
            await Task.yield()
        }
        #expect(replacementWakeupDraws == 0)
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
