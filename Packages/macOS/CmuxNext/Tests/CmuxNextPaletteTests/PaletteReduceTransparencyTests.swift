import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
import Testing

/// The palette is an overlay surface: under Reduce Transparency (injected,
/// never the system toggle) it draws the opaque theme fill, and it follows
/// the setting live.
@MainActor @Suite struct PaletteReduceTransparencyTests {
    @Test func thePaletteResolvesThroughTheOverlaySurface() throws {
        ReduceTransparency.override = true
        defer { ReduceTransparency.override = nil }
        let view = PaletteContentView(model: PaletteModel(persistence: nil))
        view.frame = NSRect(origin: .zero, size: PaletteLayout.windowSize)
        view.layoutSubtreeIfNeeded()
        #expect(view.glass.material == .opaque)
        #expect(!(view.glass.materialDrawingView is NSGlassEffectView))
        #expect(view.searchBar.isDescendant(of: view.glass.contentView))
        let fill = try #require(view.glass.materialDrawingView?.layer?.backgroundColor)
        #expect(fill.alpha == 1)
        ReduceTransparency.override = false
        #expect(view.glass.material == .liquidGlass)
        #expect(view.glass.materialDrawingView is NSGlassEffectView)
        #expect(view.searchBar.isDescendant(of: view.glass.contentView))
    }
}
