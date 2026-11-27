import CmuxTerminalCore
import Foundation
import GhosttyKit
import Testing
@testable import CmuxTerminal

/// Mirrors native runtime creation for synthetic test surfaces. Callbacks and
/// their pending tokens remain owned by the C stub, including recovery probes.
@MainActor
func makeRendererCallbackContextForTesting(
    on surface: TerminalSurface,
    rendererMailboxDidDrain: @escaping @Sendable (UUID) -> Void = { _ in }
) -> Unmanaged<GhosttySurfaceCallbackContext> {
    let target = TerminalSurfaceCallbackTarget(surface: surface)
    let context = Unmanaged.passRetained(GhosttySurfaceCallbackContext(
        surfaceHost: surface.surfaceView,
        surfaceController: surface,
        terminalLifecycleID: surface.terminalLifecycleId,
        rendererMailboxDidDrain: rendererMailboxDidDrain,
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
    surface.surfaceCallbackContext?.release()
    surface.surfaceCallbackContext = context
    return context
}

@MainActor
func registerRendererCallbacksForTesting(
    on surface: TerminalSurface,
    runtimeSurface: ghostty_surface_t
) {
    guard let context = surface.surfaceCallbackContext else {
        Issue.record("Renderer fixture must install its callback context before registration")
        return
    }
    #expect(ghostty_surface_set_render_presented_callback(
        runtimeSurface, terminalRendererPresentedCallback, context.toOpaque()
    ))
    #expect(ghostty_surface_set_render_failed_callback(
        runtimeSurface, terminalRendererFailedCallback, context.toOpaque()
    ))
}
