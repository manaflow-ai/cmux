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
        #expect(panel.contentView === surface.superview)
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

    /// The bubble is a popup (#18729 natively): the shared radius and the card's one 12% shadow, no
    /// window shadow, and the card where the editor places it.
    @Test func theEditorIsAPopup() throws {
        let panel = TabGroupEditorPanel()
        let surface = try #require(panel.glass)
        #expect(!panel.hasShadow)
        #expect(surface.cornerRadius == PopupStyle.cornerRadius)
        let host = try #require(panel.contentView as? PopupHostView)
        #expect(host.card === surface)
        #expect(host.shadowLayer.shadowOpacity == Float(PopupStyle.shadowAlpha))
    }
}
