import AppKit
import CmuxTerminalCore
import GhosttyKit
@testable import CmuxTerminal

@_silgen_name("cmux_test_ghostty_renderer_present")
private func presentRendererFrame(_ surface: UnsafeMutableRawPointer) -> Bool

@_silgen_name("cmux_test_ghostty_renderer_fail")
private func failRendererFrame(
    _ surface: UnsafeMutableRawPointer,
    _ status: Int32
) -> Bool

@MainActor
func acknowledgePresentation(on surface: TerminalSurface) {
    guard let runtimeSurface = surface.surface else { return }
    _ = presentRendererFrame(runtimeSurface)
}

@MainActor
func failPresentation(
    on surface: TerminalSurface,
    status: ghostty_render_presentation_status_e
) -> Bool {
    guard let runtimeSurface = surface.surface else { return false }
    return failRendererFrame(runtimeSurface, Int32(status.rawValue))
}

@MainActor
func installRendererCallbackContext(
    on surface: TerminalSurface,
    scheduler: FakeRendererRealizationScheduler
) -> Unmanaged<GhosttySurfaceCallbackContext> {
    let callbackTarget = TerminalSurfaceCallbackTarget(surface: surface)
    let callbackContext = Unmanaged.passRetained(GhosttySurfaceCallbackContext(
        surfaceHost: surface.surfaceView,
        surfaceController: surface,
        terminalLifecycleID: surface.terminalLifecycleId,
        rendererMailboxDidDrain: { surfaceID in
            MainActor.assumeIsolated {
                scheduler.scheduleRendererPresentationRepair(surfaceID: surfaceID)
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
    surface.surfaceCallbackContext?.release()
    surface.surfaceCallbackContext = callbackContext
    return callbackContext
}
