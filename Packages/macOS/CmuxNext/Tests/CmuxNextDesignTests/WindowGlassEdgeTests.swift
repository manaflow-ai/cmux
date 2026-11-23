import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// The user, 2026-11-19, on macOS 27 with Clear Glass over a picture: "weird white border at top of
/// window we gotta fix". Liquid Glass draws a bright highlight along its own edges, strongest at the
/// top and bottom. The window backdrop's glass filled the window edge to edge, so that highlight lay
/// on the window's own rim: in a real capture the top edge was 72 levels over the content and the
/// sides 16, where an opaque window has 18 on every side. The window's glass runs past every edge of
/// the window, so the window clips the glass's highlight and keeps one even rim on all four sides.
@MainActor @Suite struct WindowGlassEdgeTests {
    /// Measured on macOS 27: the glass's highlight and lens band are gone from the window's edge once
    /// the glass runs 4 points past it.
    static let clipped: CGFloat = 4

    @Test(arguments: [-1, -2])
    func theWindowGlassRunsPastEveryEdgeOfTheWindow(blur: Int) throws {
        let surface = WindowSurfaceView(content: NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200)), activeLook: nil,
                                        reduceTransparency: { false })
        let backdrop = surface.backdropView
        backdrop.apply(WindowBackdrop(backgroundOpacity: 0.55, backgroundBlur: blur, liquidGlass: true), tint: .black)
        let glass = try #require(backdrop.materialView, "glass draws a material view")
        // The window resizes: the glass keeps running past every edge.
        for size in [NSSize(width: 320, height: 200), NSSize(width: 1100, height: 700), NSSize(width: 500, height: 260)] {
            surface.setFrameSize(size)
            let edge = backdrop.convert(glass.frame, to: surface)
            #expect(edge.minX <= -Self.clipped && edge.minY <= -Self.clipped, "\(size): the glass's left and bottom edges \(edge) lie past the window's")
            #expect(edge.maxX >= size.width + Self.clipped && edge.maxY >= size.height + Self.clipped,
                    "\(size): the glass's right and top edges \(edge) lie past the window's")
        }
    }

    /// A pane's own picture sits inside the window, beside other panes: its glass stays inside it.
    @Test func aBackdropInsideTheWindowKeepsItsGlassInside() throws {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        view.apply(WindowBackdrop(backgroundOpacity: 0.55, backgroundBlur: -2, liquidGlass: true), tint: .black)
        let glass = try #require(view.materialView)
        #expect(glass.frame == view.bounds)
    }
}
