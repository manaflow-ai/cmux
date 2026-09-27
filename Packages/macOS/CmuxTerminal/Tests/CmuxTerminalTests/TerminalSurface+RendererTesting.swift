import CmuxTerminalCore
import GhosttyKit
import GhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

extension TerminalSurface {
    /// Installs the native callback contract for a synthetic renderer runtime.
    @MainActor
    @discardableResult
    func installRendererCallbacksForTesting(
        on runtimeSurface: UnsafeMutableRawPointer,
        scheduler: FakeRendererRealizationScheduler? = nil
    ) -> Unmanaged<GhosttySurfaceCallbackContext> {
        // The C stub delivers these callbacks synchronously from MainActor tests.
        let target = TerminalSurfaceCallbackTarget(surface: self)
        let context = Unmanaged.passRetained(GhosttySurfaceCallbackContext(
            surfaceHost: surfaceView,
            surfaceController: self,
            terminalLifecycleID: terminalLifecycleId,
            rendererMailboxDidDrain: { surfaceID in
                MainActor.assumeIsolated {
                    scheduler?.scheduleRendererPresentationRepair(surfaceID: surfaceID)
                }
            },
            rendererFramePresented: { _, token in
                MainActor.assumeIsolated {
                    target.surface?.rendererFrameDidPresent(token: token)
                }
            },
            rendererFrameFailed: { _, token, status in
                MainActor.assumeIsolated {
                    target.surface?.rendererFrameDidFail(token: token, status: status)
                }
            }
        ))
        surfaceCallbackContext?.release()
        surfaceCallbackContext = context
        #expect(ghostty_surface_set_render_presented_callback(
            runtimeSurface,
            terminalRendererPresentedCallback,
            context.toOpaque()
        ))
        #expect(ghostty_surface_set_render_failed_callback(
            runtimeSurface,
            terminalRendererFailedCallback,
            context.toOpaque()
        ))
        return context
    }
}
