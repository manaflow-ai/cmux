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
        let standard = PopupStyle.standard
        #expect(shadow.shadowBlurRadius == standard.shadowBlur)
        #expect(shadow.shadowOffset == NSSize(width: 0, height: -standard.shadowOffset))
        #expect(abs((shadow.shadowColor?.alphaComponent ?? 0) - standard.shadowAlpha) < 0.001)
    }

    private static func shadows(in view: NSView) -> [NSShadow] {
        (view.shadow.map { [$0] } ?? []) + view.subviews.flatMap(shadows(in:))
    }
}
