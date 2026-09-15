import GhosttyKit
import GhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

extension TerminalSurface {
    /// Synthetic runtimes still use the native token/callback handshake. The
    /// fixture owns the surface until releaseSurfaceForTesting clears callbacks.
    @MainActor
    func installRendererTestCallbacks(_ runtime: UnsafeMutableRawPointer) {
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        #expect(ghostty_surface_set_render_presented_callback(runtime, { userdata, token in
            guard let userdata else { return }
            MainActor.assumeIsolated {
                Unmanaged<TerminalSurface>.fromOpaque(userdata).takeUnretainedValue().rendererFrameDidPresent(token: token)
            }
        }, userdata))
        #expect(ghostty_surface_set_render_failed_callback(runtime, { userdata, token, status in
            guard let userdata else { return }
            MainActor.assumeIsolated {
                Unmanaged<TerminalSurface>.fromOpaque(userdata).takeUnretainedValue().rendererFrameDidFail(
                    token: token, status: status
                )
            }
        }, userdata))
    }

    @MainActor
    func acknowledgeRendererTestPresentation() {
        guard rendererPresentationState.inFlightToken != nil, let surface else { return }
        #expect(cmux_test_ghostty_renderer_present(surface))
    }

    @MainActor
    func failRendererTestPresentation() {
        guard let surface else { Issue.record("expected a runtime surface"); return }
        #expect(cmux_test_ghostty_renderer_fail(surface, Int32(GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED.rawValue)))
    }
}
