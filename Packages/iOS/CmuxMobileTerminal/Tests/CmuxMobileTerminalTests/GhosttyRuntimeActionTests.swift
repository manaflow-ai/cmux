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
