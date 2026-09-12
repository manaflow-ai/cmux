import AppKit
import GhosttyKit
import Testing
@testable import CmuxTerminal

/// The overlay belongs to the terminal content viewport, which can be smaller
/// than the surrounding pane when a maximum content width is configured.
@MainActor
@Suite(.serialized) struct TerminalRenderHealthOverlayControllerTests {
    @Test func healthOverlayKeepsTheLatestContentFrameForBothDiagnostics() async throws {
        let fixture = PresentedSurfaceFixture()
        defer { fixture.tearDown() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let controller = TerminalRenderHealthOverlayController()
        controller.attach(host: host, surface: fixture.surface)

        let contentFrame = NSRect(x: 40, y: 30, width: 320, height: 220)
        controller.updateFrame(contentFrame)
        fixture.surface.setRendererPortalVisible(false)
        fixture.surface.setRendererPortalVisible(true)
        guard let token = fixture.surface.rendererPresentationState.inFlightToken else {
            Issue.record("expected a presentation probe")
            return
        }
        fixture.surface.rendererFrameDidFail(
            token: token,
            status: GHOSTTY_RENDER_PRESENTATION_BACKEND_FAILED
        )
        await Task.yield()
        let overlay = try #require(host.subviews.compactMap {
            $0 as? TerminalRenderHealthOverlayView
        }.first)
        #expect(overlay.frame == contentFrame)

        fixture.surface.markShellExited()
        await Task.yield()
        #expect(overlay.frame == contentFrame)
    }
}
