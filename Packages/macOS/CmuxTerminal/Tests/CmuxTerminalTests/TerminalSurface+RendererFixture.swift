import CmuxTerminalCore
import Foundation
import GhosttyKit
import GhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

/// Keeps renderer fixtures on the same callback admission contract as Ghostty.
@MainActor
extension TerminalSurface {
    /// Installs retained userdata before the fixture registers native callbacks.
    @discardableResult
    func installRendererCallbackContextForTesting(
        rendererMailboxDidDrain: @escaping @MainActor @Sendable (UUID) -> Void = { _ in }
    ) -> Unmanaged<GhosttySurfaceCallbackContext> {
        let callbackTarget = TerminalSurfaceCallbackTarget(surface: self)
        let context = Unmanaged.passRetained(GhosttySurfaceCallbackContext(
            surfaceHost: surfaceView,
            surfaceController: self,
            terminalLifecycleID: terminalLifecycleId,
            rendererMailboxDidDrain: { surfaceID in
                MainActor.assumeIsolated {
                    rendererMailboxDidDrain(surfaceID)
                }
            },
            rendererFramePresented: { _, token in
                MainActor.assumeIsolated {
                    callbackTarget.surface?.rendererFrameDidPresent(token: token)
                }
            },
            rendererFrameFailed: { _, token, status in
                MainActor.assumeIsolated {
                    callbackTarget.surface?.rendererFrameDidFail(token: token, status: status)
                }
            }
        ))
        surfaceCallbackContext?.release()
        surfaceCallbackContext = context
        return context
    }

    /// Registers callbacks before any runtime-created presentation probe.
    func installRendererRuntimeSurfaceForTesting(_ runtimeSurface: UnsafeMutableRawPointer) {
        let context = surfaceCallbackContext ?? installRendererCallbackContextForTesting()
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
        installRuntimeSurfaceForTesting(runtimeSurface)
    }

    /// Explicit delivery also retires the pending token held by the C stub.
    func acknowledgeRendererPresentationForTesting() {
        guard rendererPresentationState.inFlightToken != nil else { return }
        guard let surface else {
            Issue.record("expected a live runtime surface for presentation")
            return
        }
        #expect(cmux_test_ghostty_renderer_present(surface))
    }

    /// Fixtures emit synchronously on the main actor instead of using a timer.
    func failRendererPresentationForTesting(status: ghostty_render_presentation_status_e) {
        guard let surface else {
            Issue.record("expected a live runtime surface for presentation failure")
            return
        }
        #expect(cmux_test_ghostty_renderer_fail(surface, Int32(status.rawValue)))
    }
}
