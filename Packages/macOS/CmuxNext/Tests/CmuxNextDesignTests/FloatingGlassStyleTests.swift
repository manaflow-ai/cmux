import AppKit
@testable import CmuxNextDesign
import Testing

/// One shared Liquid Glass look for toasts, dialogs and the sidebar's bottom-left cards (user,
/// 2026-10-20, after Rex): neutral gray glass, a soft top-lit rim, continuous corners, correct in
/// light and dark; opaque under Reduce Transparency.
@MainActor
struct FloatingGlassStyleTests {
    private static func reduceTransparency(_ on: Bool) -> ReduceTransparency {
        ReduceTransparency(system: { on }, changes: NotificationCenter())
    }

    /// The look's veil is gray (the toast paints it in the theme's tint, ``Palette/veil(of:)``),
    /// and the rim is brighter at the top than the bottom.
    @Test(arguments: [false, true])
    func theLookIsNeutralWithATopLitRim(isDark: Bool) {
        for style in [FloatingGlassStyle.toast, .dialog, .card] {
            let look = style.look(isDark: isDark)
            #expect(look.veil.alpha > 0 && look.veil.alpha < 1)
            #expect(look.rimTop.alpha > look.rimBottom.alpha)
            #expect(look.rimTop.alpha > 0)
        }
        // Dark glass is a dark veil, light glass a light one.
        let toast = FloatingGlassStyle.toast.look(isDark: isDark)
        #expect(isDark ? toast.veil.white < 0.5 : toast.veil.white > 0.5)
    }

    /// The confirm dialog's card (the sheet glass the dialog drawing puts under the overlay page)
    /// uses the same neutral glass; its rim draws unless the picked variant is Apple's Liquid Glass with
    /// its own edge (``OverlayGlassVariant``).
    @Test func theDialogUsesTheSharedGlass() throws {
        let surface = Glass.makeSurface(.sheet, content: NSView())
        #expect(surface.tone == .neutral)
        let ownEdge = surface.material == .liquidGlass && OverlayGlassVariant.picked == .appKitRegular
        if surface.material != .opaque { #expect((surface.rimView != nil) == !ownEdge) }
    }

    /// The sidebar's bottom-left cards (tips, Update Ready) draw the neutral veil and the rim,
    /// not the flat 13% text fill.
    @Test func theSidebarCardDrawsTheNeutralVeilAndRim() throws {
        let card = CardSurfaceView(reduceTransparency: Self.reduceTransparency(false))
        card.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
        card.appearance = NSAppearance(named: .darkAqua)
        card.updateLayer()
        #expect(card.rimView != nil)
        let fill = try #require(card.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        let veil = FloatingGlassStyle.card.look(isDark: card.themeTokens.isDark).veil
        #expect(abs(fill.alphaComponent - veil.alpha) < 0.02)
        #expect(abs(fill.redComponent - fill.greenComponent) < 0.01 && abs(fill.greenComponent - fill.blueComponent) < 0.01)
    }
}
