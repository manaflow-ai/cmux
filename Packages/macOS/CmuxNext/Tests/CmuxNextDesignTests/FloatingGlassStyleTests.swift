import AppKit
@testable import CmuxNextDesign
import Testing

/// One shared Liquid Glass look for toasts, dialogs and the sidebar's bottom-left cards (user,
/// 2026-10-20, after Rex): neutral gray glass, a soft top-lit rim, continuous corners, correct in
/// light and dark; opaque under Reduce Transparency.
@MainActor
struct FloatingGlassStyleTests {
    private static func reduceTransparency(_ on: Bool) -> ReduceTransparency {
        ReduceTransparency(system: { on })
    }

    private static func surface(of view: NSView) throws -> OverlaySurfaceView {
        try #require(view.subviews.compactMap { $0 as? OverlaySurfaceView }.first)
    }

    /// The veil is gray, never a theme hue, and the rim is brighter at the top than the bottom.
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

    /// The toast is glass (not the opaque surface) with the neutral tone and a rim.
    @Test func theToastIsNeutralGlassWithARim() throws {
        let view = CmuxToastView(toast: CmuxToast(id: "t", message: "Restart cmux-tui to use new features"),
                                 reduceTransparency: Self.reduceTransparency(false))
        let surface = try Self.surface(of: view)
        #expect(surface.material != .opaque)
        #expect(surface.tone == .neutral)
        #expect(surface.rimView != nil)
        #expect(surface.cornerRadius == FloatingGlassStyle.toast.cornerRadius)
    }

    /// Reduce Transparency still gets the opaque theme surface, with no rim.
    @Test func reduceTransparencyKeepsTheToastOpaque() throws {
        let view = CmuxToastView(toast: CmuxToast(id: "t", message: "Saved"),
                                 reduceTransparency: Self.reduceTransparency(true))
        let surface = try Self.surface(of: view)
        #expect(surface.material == .opaque)
        #expect(surface.rimView == nil)
    }

    /// The confirm dialog uses the same neutral glass and rim.
    @Test func theDialogUsesTheSharedGlass() throws {
        let dialog = CmuxDialogView(spec: CmuxDialogSpec(title: "Restart cmux-tui?", lines: ["Terminals keep running."],
                                                         buttons: [.cancel(), .ok("Restart")]))
        let surface = try #require(dialog.surface)
        #expect(surface.tone == .neutral)
        if surface.material != .opaque { #expect(surface.rimView != nil) }
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
