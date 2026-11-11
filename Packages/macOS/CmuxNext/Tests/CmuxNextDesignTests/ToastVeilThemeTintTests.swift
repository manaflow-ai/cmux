import AppKit
import CmuxNextTestSupport
import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// Leo 2026-11-07: "these toasts are still coloured unthemed". The toast's glass carried the
/// neutral gray veil in every theme; it lays the theme's glass tint (the theme background, as the
/// popovers' glass) at the toast's veil opacity, so a red theme's toast is red glass. The toast
/// role's glass is the one each native toast draws on (`CmuxToastView`).
@MainActor @Suite(.serialized, .closesItsWindows)
struct ToastVeilThemeTintTests {
    /// The colour the surface lays over its glass: the Liquid Glass tint or the vibrancy tint
    /// layer, never its content or its rim.
    private static func paintedVeil(_ surface: OverlaySurfaceView) -> NSColor? {
        var stack = surface.subviews
        while let view = stack.popLast() {
            if view === surface.contentView || view.isDescendant(of: surface.contentView) || view is GlassRimView { continue }
            if let glass = view as? GlassPanelView, let tint = glass.tintColor { return tint.usingColorSpace(.sRGB) }
            if let fill = view.layer?.backgroundColor, let color = NSColor(cgColor: fill), color.alphaComponent > 0 {
                return color.usingColorSpace(.sRGB)
            }
            stack += view.subviews
        }
        return nil
    }

    @Test func theToastVeilTakesTheThemesTint() throws {
        let theme = try #require(try CardNeverOpaqueTests.bundledThemes().first { $0.name == "Hot Dog Stand" })
        let scope = ThemeScope(level: .room)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)
        scope.root(root)
        // The toast role's glass with Reduce Transparency off (the glass, not the opaque fallback).
        let surface = OverlaySurfaceView(interactive: false, cornerRadius: SurfaceRole.toast.cornerRadius,
                                         reduceTransparency: ReduceTransparency(system: { false }, changes: NotificationCenter()),
                                         tone: SurfaceRole.toast.tone)
        surface.frame = NSRect(x: 20, y: 20, width: 300, height: 44)
        root.addSubview(surface)
        scope.setOverride(try #require(ThemeSpec("Glass \(theme.name)")), input: theme.input, animated: false)
        root.layoutSubtreeIfNeeded()
        #expect(surface.material != .opaque)
        let painted = try #require(Self.paintedVeil(surface))
        let wanted = Palette.veilRGB(of: .toast, tokens: scope.tokens)
        let gray = FloatingGlassStyle.toast.look(isDark: scope.tokens.isDark).veil
        let channels: [(Double, Double)] = [(Double(painted.redComponent), wanted.red), (Double(painted.greenComponent), wanted.green),
                                            (Double(painted.blueComponent), wanted.blue), (Double(painted.alphaComponent), gray.alpha)]
        for (shown, expected) in channels { #expect(abs(shown - expected) < 0.02, "veil \(painted), wanted \(wanted)") }
        let hue = Double(painted.redComponent) - Double(painted.blueComponent)
        #expect(hue > 0.2, "the veil carries the theme's red, not the gray: \(painted)")
    }
}
