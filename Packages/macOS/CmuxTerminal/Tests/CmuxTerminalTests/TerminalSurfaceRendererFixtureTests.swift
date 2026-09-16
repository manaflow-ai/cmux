import AppKit
import GhosttyKit
import GhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

@MainActor
@Suite(.serialized) struct TerminalSurfaceRendererFixtureTests {
    @Test func fixtureRegistersAndConsumesPresentationTokens() {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface

        #expect(surface.isNativeViewInRealWindow)
        #expect(surface.isRendererPresented)
        #expect(!cmux_test_ghostty_renderer_present(fixture.runtimeSurface))

        surface.rendererRuntimeSurfaceDidCreate()
        #expect(surface.renderHealth == .awaitingFrame)
        #expect(!ghostty_surface_request_render_with_token(fixture.runtimeSurface, 999))
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(surface.isRendererPresented)
        #expect(!cmux_test_ghostty_renderer_present(fixture.runtimeSurface))

        surface.setRendererPortalVisible(false)
        surface.setRendererPortalVisible(true)
        #expect(surface.renderHealth == .awaitingFrame)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(surface.isRendererPresented)
    }
}
