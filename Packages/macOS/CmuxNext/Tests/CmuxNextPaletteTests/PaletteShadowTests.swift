import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
import Testing

/// POLISH (subtle shadows, one shared popover elevation): the palette cast its own shadow, black at
/// 22% with a 28 pt blur, so it and its actions menu looked heavier than every other popup. It
/// casts the shared popup shadow (`PopupStyle.standard`).
@MainActor struct PaletteShadowTests {
    @Test func thePaletteCastsTheSharedPopupShadow() throws {
        _ = NSApplication.shared
        let content = PaletteContentView(model: PaletteModel())
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        defer { window.orderOut(nil) }
        let shadows = Self.shadows(in: content)
        #expect(shadows.count == 1)
        let shadow = try #require(shadows.first)
        let elevation = PopupStyle.standard.elevation
        #expect(shadow.shadowBlurRadius == elevation.blur)
        #expect(shadow.shadowOffset == NSSize(width: 0, height: -elevation.offset))
        #expect(abs((shadow.shadowColor?.alphaComponent ?? 0) - elevation.alpha) < 0.001)
    }

    @Test func theActionsMenuOpensInOneFrame() {
        _ = NSApplication.shared
        let content = PaletteContentView(model: PaletteModel())
        content.animateActionsMenu(appearing: true)

        #expect(!content.actionsMenuView.isHidden)
        #expect(content.actionsMenuView.alphaValue == 1)
        #expect(content.actionsMenuView.layer?.animation(forKey: "opacity") == nil)
        #expect(content.actionsMenuView.layer?.animation(forKey: "sublayerTransform") == nil)
    }

    private static func shadows(in view: NSView) -> [NSShadow] {
        (view.shadow.map { [$0] } ?? []) + view.subviews.flatMap(shadows(in:))
    }
}
