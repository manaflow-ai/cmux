import AppKit
import CmuxTerminalFrontend
import QuartzCore
import Testing

@MainActor
@Suite struct TerminalFrontendSurfaceViewTests {
    @Test func visualSurfaceUsesPlainLayerAndPassesInteractionToAdapter() throws {
        let surface = TerminalFrontendSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let compositorPlaceholder = NSView(frame: surface.bounds)
        surface.addSubview(compositorPlaceholder)

        let backingLayer = try #require(surface.layer)

        #expect(type(of: backingLayer) == CALayer.self)
        #expect(!(backingLayer is CAMetalLayer))
        #expect(surface.hitTest(NSPoint(x: 10, y: 10)) == nil)
        #expect(surface.acceptsFirstResponder == false)
    }
}
