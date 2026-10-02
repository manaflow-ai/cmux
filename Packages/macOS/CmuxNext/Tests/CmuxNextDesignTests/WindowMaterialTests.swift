import AppKit
import Testing
@testable import CmuxNextDesign

/// One material for the whole window (#16688): `WindowBackdrop` picks it
/// from the resolved opacity, blur and Reduce Transparency, and the panes
/// stay clear over every material.
struct WindowMaterialTests {
    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        let opacity: Double
        let blur: Int
        let reduceTransparency: Bool
        let material: WindowMaterial
        var testDescription: String { "opacity \(opacity), blur \(blur), reduce transparency \(reduceTransparency)" }
    }

    nonisolated static let cases: [Case] = [
        Case(opacity: 1, blur: 0, reduceTransparency: false, material: .opaque),
        Case(opacity: 1, blur: 20, reduceTransparency: false, material: .opaque),
        // A translucent window with no blur stays plainly see-through.
        Case(opacity: 0.8, blur: 0, reduceTransparency: false, material: .translucent),
        Case(opacity: 0, blur: 0, reduceTransparency: false, material: .translucent),
        Case(opacity: 0.8, blur: 20, reduceTransparency: false, material: .frosted),
        Case(opacity: 0.5, blur: 1, reduceTransparency: false, material: .frosted),
        Case(opacity: 1, blur: -1, reduceTransparency: false, material: .glass(.regular)),
        Case(opacity: 0.7, blur: -1, reduceTransparency: false, material: .glass(.regular)),
        Case(opacity: 1, blur: -2, reduceTransparency: false, material: .glass(.clear)),
        Case(opacity: 0.6, blur: -2, reduceTransparency: false, material: .glass(.clear)),
        Case(opacity: 1, blur: 0, reduceTransparency: true, material: .opaque),
        Case(opacity: 0.8, blur: 0, reduceTransparency: true, material: .opaque),
        Case(opacity: 0.8, blur: 20, reduceTransparency: true, material: .opaque),
        Case(opacity: 1, blur: -1, reduceTransparency: true, material: .opaque),
        Case(opacity: 0.6, blur: -2, reduceTransparency: true, material: .opaque),
    ]

    @Test(arguments: cases)
    func theMaterialFollowsOpacityBlurAndReduceTransparency(_ c: Case) {
        let backdrop = WindowBackdrop(backgroundOpacity: c.opacity, backgroundBlur: c.blur, reduceTransparency: c.reduceTransparency)
        #expect(backdrop.material == c.material)
        #expect(backdrop.isOpaque == (c.material == .opaque))
        // Panes and the agent pane stay clear over every material.
        #expect(backdrop.panesPaintBackground == (c.material == .opaque))
        // The tint over the material is the resolved opacity.
        #expect(backdrop.tintOpacity == (c.material == .opaque ? 1 : c.opacity))
    }

    /// Only frosted puts a radius on the window, its own `background-blur`;
    /// every other material clears it.
    @Test(arguments: [(0.8, 20, 20), (0.5, 1, 1), (0.8, 12, 12), (0.8, 0, 0), (0.8, -1, 0), (0.8, -2, 0), (1.0, 20, 0), (1.0, 0, 0)])
    func onlyFrostedSetsAWindowBlurRadius(opacity: Double, blur: Int, radius: Int) {
        #expect(WindowBackdrop(backgroundOpacity: opacity, backgroundBlur: blur).windowBlurRadius == radius)
        #expect(WindowBackdrop(backgroundOpacity: opacity, backgroundBlur: blur, reduceTransparency: true).windowBlurRadius == 0)
    }

    @Test func theTokensInitReadsTheResolvedValues() {
        var input = ThemeFixtures.catppuccinMocha
        input.backgroundOpacity = 0.75
        input.backgroundBlur = -2
        let tokens = ThemeTokens.derive(from: input)
        #expect(WindowBackdrop(tokens).material == .glass(.clear))
        #expect(WindowBackdrop(tokens).tintOpacity == 0.75)
        #expect(WindowBackdrop(tokens, reduceTransparency: true).material == .opaque)
    }
}

/// cmux.json's `appearance.backgroundOpacity` / `appearance.backgroundBlur`
/// over Ghostty's values: the one rule the surfaces and tokens share.
struct WindowBackgroundOverrideTests {
    static func same(_ resolved: (backgroundOpacity: Double, backgroundBlur: Int), _ opacity: Double, _ blur: Int) -> Bool {
        resolved.backgroundOpacity == opacity && resolved.backgroundBlur == blur
    }

    @Test func noOverrideKeepsGhosttysValues() {
        let none = WindowBackgroundOverride()
        #expect(Self.same(none.resolved(backgroundOpacity: 1, backgroundBlur: 0), 1, 0))
        #expect(Self.same(none.resolved(backgroundOpacity: 0.85, backgroundBlur: 20), 0.85, 20))
        #expect(Self.same(none.resolved(backgroundOpacity: 1, backgroundBlur: -1), 1, -1))
    }

    @Test func theOpacityAndMaterialReplaceGhosttys() {
        #expect(Self.same(WindowBackgroundOverride(opacity: 0.6).resolved(backgroundOpacity: 1, backgroundBlur: 0), 0.6, 0))
        #expect(Self.same(WindowBackgroundOverride(opacity: 1).resolved(backgroundOpacity: 0.7, backgroundBlur: 20), 1, 20))
        #expect(Self.same(WindowBackgroundOverride(opacity: 0.6, material: .glass).resolved(backgroundOpacity: 0.9, backgroundBlur: 0), 0.6, -1))
        #expect(Self.same(WindowBackgroundOverride(opacity: 0.6, material: .glassClear).resolved(backgroundOpacity: 0.9, backgroundBlur: 20), 0.6, -2))
        // Frosted needs a radius; Ghostty's default (20) when the config has none.
        #expect(Self.same(WindowBackgroundOverride(opacity: 0.6, material: .frosted).resolved(backgroundOpacity: 0.9, backgroundBlur: -1),
                          0.6, WindowBackgroundOverride.defaultFrostedRadius))
        #expect(Self.same(WindowBackgroundOverride(material: .frosted).resolved(backgroundOpacity: 0.9, backgroundBlur: 12), 0.9, 12))
    }

    /// Picking a material asks for translucency: over an opaque Ghostty
    /// config the window takes the default translucent opacity, while a
    /// Ghostty opacity below 1 is kept.
    @Test func aMaterialAloneMakesAnOpaqueConfigTranslucent() {
        let frosted = WindowBackgroundOverride(material: .frosted)
        let radius = WindowBackgroundOverride.defaultFrostedRadius
        #expect(Self.same(frosted.resolved(backgroundOpacity: 1, backgroundBlur: 0), WindowBackgroundOverride.defaultTranslucentOpacity, radius))
        #expect(Self.same(frosted.resolved(backgroundOpacity: 0.9, backgroundBlur: 0), 0.9, radius))
        #expect(WindowBackdrop(backgroundOpacity: 0.9, backgroundBlur: radius).material == .frosted)
        let glass = WindowBackgroundOverride(material: .glass)
        #expect(Self.same(glass.resolved(backgroundOpacity: 1, backgroundBlur: 0), WindowBackgroundOverride.defaultTranslucentOpacity, -1))
        #expect(WindowBackgroundOverride.defaultTranslucentOpacity < 1)
    }

    /// `none` drops the blur and keeps the opacity: see-through below 1,
    /// opaque at 1. It does not ask for translucency, so an opaque config
    /// stays opaque (no default opacity).
    @Test func noneDropsTheBlurAndKeepsTheOpacity() {
        let unblurred = WindowBackgroundOverride(opacity: 0.5, material: .unblurred)
        #expect(Self.same(unblurred.resolved(backgroundOpacity: 0.7, backgroundBlur: -1), 0.5, 0))
        #expect(WindowBackdrop(backgroundOpacity: 0.5, backgroundBlur: 0).material == .translucent)
        let alone = WindowBackgroundOverride(material: .unblurred)
        #expect(Self.same(alone.resolved(backgroundOpacity: 0.7, backgroundBlur: 20), 0.7, 0))
        #expect(Self.same(alone.resolved(backgroundOpacity: 1, backgroundBlur: 20), 1, 0))
        #expect(WindowBackdrop(backgroundOpacity: 1, backgroundBlur: 0).material == .opaque)
    }

    /// The Ghostty config already carries the resolved values when the theme
    /// reads them; resolving again must not move them.
    @Test(arguments: [WindowBackgroundOverride(), WindowBackgroundOverride(opacity: 0.6), WindowBackgroundOverride(material: .frosted),
                      WindowBackgroundOverride(material: .glassClear), WindowBackgroundOverride(opacity: 0.3, material: .unblurred), WindowBackgroundOverride(material: .unblurred)])
    func resolvingTwiceChangesNothing(_ override: WindowBackgroundOverride) {
        for (opacity, blur) in [(1.0, 0), (0.8, 20), (1.0, -1)] {
            let once = override.resolved(backgroundOpacity: opacity, backgroundBlur: blur)
            let twice = override.resolved(backgroundOpacity: once.backgroundOpacity, backgroundBlur: once.backgroundBlur)
            #expect(Self.same(twice, once.backgroundOpacity, once.backgroundBlur))
        }
    }
}

/// The window root's backdrop view: exactly one material view of the
/// material's class, none while opaque, and one tint at the resolved
/// opacity.
@MainActor struct WindowMaterialViewTests {
    private func materialViews(in view: NSView) -> [NSView] {
        view.subviews.filter { $0 is NSVisualEffectView || $0 is NSGlassEffectView }
    }

    /// Frosted is the tint alone; the window's blur radius frosts the
    /// desktop under it. A behind-window effect view here painted the
    /// window opaque.
    @Test func frostedHostsOnlyTheTint() throws {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let backdrop = WindowBackdrop(backgroundOpacity: 0.7, backgroundBlur: 20)
        view.apply(backdrop, tint: .black)
        #expect(view.material == .frosted)
        #expect(backdrop.windowBlurRadius == 20)
        #expect(materialViews(in: view).isEmpty)
        #expect(view.materialView == nil)
        let tint = try #require(view.tintColor)
        #expect(abs(tint.alpha - 0.7) < 0.001)
    }

    @Test(arguments: [(-1, NSGlassEffectView.Style.regular), (-2, NSGlassEffectView.Style.clear)])
    func glassHostsOneGlassView(blur: Int, style: NSGlassEffectView.Style) throws {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.apply(WindowBackdrop(backgroundOpacity: 0.55, backgroundBlur: blur), tint: .black)
        #expect(materialViews(in: view).count == 1)
        let glass = try #require(view.materialView as? NSGlassEffectView)
        #expect(glass.style == style)
        let tint = try #require(view.tintColor)
        #expect(abs(tint.alpha - 0.55) < 0.001)
    }

    /// Plain see-through: no material view, only the tint at the opacity.
    @Test func translucentHostsOnlyTheTint() throws {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.apply(WindowBackdrop(backgroundOpacity: 0.65, backgroundBlur: 0), tint: .black)
        #expect(view.material == .translucent)
        #expect(materialViews(in: view).isEmpty)
        #expect(view.materialView == nil)
        let tint = try #require(view.tintColor)
        #expect(abs(tint.alpha - 0.65) < 0.001)
    }

    @Test func opaqueHostsNoMaterialAndNoTint() {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.apply(WindowBackdrop(backgroundOpacity: 1, backgroundBlur: 20), tint: .black)
        #expect(materialViews(in: view).isEmpty)
        #expect(view.materialView == nil)
        #expect(view.tintColor == nil)
    }

    /// Switching material replaces the one view; it never stacks a second.
    @Test func switchingMaterialKeepsOneView() {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.apply(WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: 20), tint: .black)
        view.apply(WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: -1), tint: .black)
        #expect(materialViews(in: view).count == 1)
        #expect(view.materialView is NSGlassEffectView)
        view.apply(WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: 20, reduceTransparency: true), tint: .black)
        #expect(materialViews(in: view).isEmpty)
        view.apply(WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: 0), tint: .black)
        #expect(materialViews(in: view).isEmpty, "see-through drops the glass")
        view.apply(WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: -2), tint: .black)
        #expect(materialViews(in: view).count == 1)
        #expect(view.materialView is NSGlassEffectView)
        view.apply(WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: 20), tint: .black)
        #expect(materialViews(in: view).isEmpty, "frosted drops the glass")
    }

    @Test func clicksPassThrough() {
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.apply(WindowBackdrop(backgroundOpacity: 0.8, backgroundBlur: 0), tint: .black)
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }
}
