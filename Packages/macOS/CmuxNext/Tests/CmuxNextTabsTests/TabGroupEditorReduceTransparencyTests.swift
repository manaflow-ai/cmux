import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// The group editor bubble is an overlay surface: under Reduce
/// Transparency (injected, never the system toggle) it draws the opaque
/// theme fill, follows the setting live, and keeps its content size.
@MainActor @Suite struct TabGroupEditorReduceTransparencyTests {
    @Test func theEditorResolvesThroughTheOverlaySurface() throws {
        ReduceTransparency.shared.override = false
        defer { ReduceTransparency.shared.override = nil }
        let panel = TabGroupEditorPanel()
        let surface = try #require(panel.glass)
        #expect(panel.contentView === surface)
        #expect(surface.material == .liquidGlass)
        let glassSize = surface.fittingSize
        #expect(glassSize.width > 0 && glassSize.height > 0)
        ReduceTransparency.shared.override = true
        #expect(surface.material == .opaque)
        #expect(!(surface.materialDrawingView is NSGlassEffectView))
        #expect(surface.materialDrawingView?.layer?.backgroundColor?.alpha == 1)
        // The bubble sizes from its content on every material.
        #expect(surface.fittingSize == glassSize)
        ReduceTransparency.shared.override = false
        #expect(surface.material == .liquidGlass)
    }
}
