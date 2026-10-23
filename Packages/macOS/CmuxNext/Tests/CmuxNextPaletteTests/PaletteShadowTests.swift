import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
import Testing

/// POLISH (subtle shadows, one shared popover elevation): the palette cast its own shadow, black at
/// 22% with a 28 pt blur, so it and its actions menu looked heavier than every other popup. It
/// casts the shared popup shadow (`PopupStyle.standard`), from the shared popup host around its
/// glass (`PopupHostView`, as every popover and hover card), never an `NSShadow` on a view above the
/// glass, which drew the shadow under the glass's see-through center (Leo 2026-10-22: "GLASS
/// IT/THEME IT PROPER").
@MainActor struct PaletteShadowTests {
    @Test func thePaletteCastsTheSharedPopupShadow() throws {
        _ = NSApplication.shared
        let content = PaletteContentView(model: PaletteModel())
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        defer { window.orderOut(nil) }
        content.layoutSubtreeIfNeeded()
        #expect(Self.shadows(in: content).isEmpty, "a view in the palette casts an NSShadow")
        let host = try #require(content.glass.superview as? PopupHostView)
        let elevation = PopupStyle.standard.elevation
        #expect(host.shadowLayer.shadowRadius == elevation.layerRadius)
        #expect(host.shadowLayer.shadowOffset == elevation.layerOffset())
        #expect(abs(CGFloat(host.shadowLayer.shadowOpacity) - elevation.alpha) < 0.001)
    }

    private static func shadows(in view: NSView) -> [NSShadow] {
        (view.shadow.map { [$0] } ?? []) + view.subviews.flatMap(shadows(in:))
    }
}
