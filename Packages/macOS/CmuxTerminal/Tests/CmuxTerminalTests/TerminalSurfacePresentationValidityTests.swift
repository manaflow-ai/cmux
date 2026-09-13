import AppKit
import GhosttyKit
import GhosttyRuntimeTestStubs
import Testing
@testable import CmuxTerminal

extension TerminalRendererTests {
@MainActor
@Suite(.serialized)
struct TerminalSurfacePresentationValidityTests {
    @Test func retiredRuntimeCannotAcknowledgeItsReplacement() throws {
        let fixture = PresentedSurfaceFixture()
        let replacement = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { fixture.tearDown(); replacement.deallocate() }
        let surface = fixture.surface
        _ = surface.requestManualOutputPresentation()
        let retiredToken = try #require(surface.rendererPresentationState.inFlightToken)
        surface.releaseSurfaceForTesting()
        fixture.registry.registerRuntimeSurface(replacement, ownerId: surface.id)
        surface.installRuntimeSurfaceForTesting(replacement)
        surface.rendererRuntimeSurfaceDidCreate(presentationReady: true)
        let replacementToken = try #require(surface.rendererPresentationState.inFlightToken)

        surface.rendererFrameDidPresent(token: retiredToken)

        #expect(!surface.isRendererPresented)
        #expect(surface.rendererPresentationState.inFlightToken == replacementToken)
        #expect(cmux_test_ghostty_renderer_present(replacement))
        #expect(surface.isRendererPresented)
    }

    @Test func hideAndRevealRetainsThePendingNativeRequest() throws {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface
        surface.setRendererPortalVisible(false, presentationReady: true)
        surface.setRendererPortalVisible(true, presentationReady: true)
        let pending = try #require(surface.rendererPresentationState.inFlightToken)

        surface.setRendererPortalVisible(false, presentationReady: true)
        surface.setRendererPortalVisible(true, presentationReady: true)

        #expect(surface.rendererPresentationState.inFlightToken == pending)
        #expect(surface.renderHealth == .awaitingFrame)
        #expect(!surface.rendererPresentationState.recoveryAttempted)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(surface.renderHealth == .awaitingFrame)
        #expect(surface.rendererPresentationState.inFlightToken != pending)
        #expect(surface.rendererPresentationState.inFlightToken != nil)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(surface.isRendererPresented)
    }

    @Test func aFrameForOldGeometryCannotMarkNewGeometryReady() throws {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface
        surface.setRendererPortalVisible(false, presentationReady: true)
        surface.setRendererPortalVisible(true, presentationReady: true)
        let pending = try #require(surface.rendererPresentationState.inFlightToken)

        surface.paneHost.frame.size.width = 500
        surface.surfaceView.frame.size.width = 500
        surface.rendererPresentationReadinessDidChange()
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))

        #expect(!surface.isRendererPresented)
        #expect(surface.renderHealth == .awaitingFrame)
        #expect(surface.rendererPresentationState.inFlightToken != pending)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(surface.isRendererPresented)
    }

    @Test func staleResizeDiscardDoesNotUseTheRecoveryAttempt() throws {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let surface = fixture.surface
        surface.setRendererPortalVisible(false, presentationReady: true)
        surface.setRendererPortalVisible(true, presentationReady: true)
        _ = try #require(surface.rendererPresentationState.inFlightToken)
        surface.surfaceView.frame.size.height = 400
        surface.rendererPresentationReadinessDidChange()

        #expect(cmux_test_ghostty_renderer_fail(
            fixture.runtimeSurface, Int32(GHOSTTY_RENDER_PRESENTATION_DISCARDED.rawValue)
        ))
        #expect(!surface.rendererPresentationState.recoveryAttempted)
        #expect(surface.renderHealth == .awaitingFrame)
        #expect(surface.rendererPresentationState.inFlightToken != nil)
        #expect(cmux_test_ghostty_renderer_present(fixture.runtimeSurface))
        #expect(surface.isRendererPresented)
    }
}

}
