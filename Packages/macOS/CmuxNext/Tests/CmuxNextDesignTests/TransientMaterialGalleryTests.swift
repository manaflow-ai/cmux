#if DEBUG
import AppKit
import CmuxNextDesignTokens
import CmuxTheme
@testable import CmuxNextDesign
import Testing

@MainActor @Suite(.serialized, .closesItsWindows)
struct TransientMaterialGalleryTests {
    private func scope(isDark: Bool) throws -> ThemeScope {
        let scope = ThemeScope(level: .room)
        let input = isDark
            ? ThemeInput(background: ThemeRGB(hex: 0x1E2430), foreground: ThemeRGB(hex: 0xF1F3F7))
            : ThemeInput(background: ThemeRGB(hex: 0xF4F6FA), foreground: ThemeRGB(hex: 0x202733))
        scope.setOverride(try #require(ThemeSpec("Transient test \(isDark ? "dark" : "light")")), input: input, animated: false)
        return scope
    }

    private func paintedMenuVeil(_ surface: OverlaySurfaceView) throws -> NSColor {
        let veil = try #require(surface.contentView.subviews.first)
        veil.updateLayer()
        let cgColor = try #require(veil.layer?.backgroundColor)
        return try #require(NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB))
    }

    /// The native capture presents four named samples twice for each kind.
    /// Menu and popover before/standard use the same current-base factory;
    /// tooltip keeps contrast-fitted role glass, and other kinds take transient.
    @Test(arguments: TransientMaterialGallery.Kind.allCases)
    func eachKindRendersBeforeAndThreeVariantsInBothThemes(kind: TransientMaterialGallery.Kind) throws {
        let cards = TransientMaterialGallery.cards(for: kind)
        #expect(cards.count == 8)
        for card in cards {
            let surface = try #require(card.view.subviews.compactMap { $0 as? OverlaySurfaceView }.first)
            #expect(!surface.isCard)
            #expect(surface.cornerRadius == kind.radius)
            #expect(surface.contentView.subviews.count > 0)
            #expect(card.view.themeTokens.isDark == card.name.contains("dark"))
        }
        let chosen = TransientMaterialGallery.makeSurface(kind: kind, variant: .standard, content: NSView())
        if kind.usesMenuMaterial {
            let before = TransientMaterialGallery.makeSurface(kind: kind, variant: .before, content: NSView())
            #expect(chosen.tone.style == nil)
            #expect(before.tone == chosen.tone)
            #expect(before.tintLevel == .menu)
            #expect(chosen.tintLevel == .menu)
            #expect(before.contentView.subviews.first is GlassMenuVeilView)
            #expect(chosen.contentView.subviews.first is GlassMenuVeilView)
            #expect(cards[0].name.contains("before (unchanged)"))
            #expect(cards[1].name.contains("standard (unchanged)"))
            #expect(cards[2].name.contains("quieter (veil fixture)"))
        } else if kind == .tooltip {
            #expect(chosen.tone.style == nil)
            #expect(chosen.cornerRadius == SurfaceRole.tooltip.cornerRadius)
        } else {
            let style = try #require(chosen.tone.style)
            #expect(style == .transient)
        }
        #expect(chosen.glassVariant == .picked)
    }

    /// The rendered veil over the real menu panel orders gallery alternatives.
    /// Its selected value stays the current-base production value in both themes.
    @Test(arguments: [false, true])
    func variantsPaintIncreasingVeilInBothThemes(isDark: Bool) throws {
        let room = try scope(isDark: isDark)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        room.root(root)
        var alphas: [CGFloat] = []
        for variant in [TransientMaterialGallery.Variant.quieter, .standard, .denser] {
            let surface = TransientMaterialGallery.makeSurface(kind: .popover, variant: variant, content: NSView())
            surface.frame = NSRect(x: 0, y: 0, width: 180, height: 60)
            surface.materialOverride = .vibrancy
            root.addSubview(surface)
            surface.applyTheme()
            alphas.append(try paintedMenuVeil(surface).alphaComponent)
        }
        #expect(alphas[0] < alphas[1] && alphas[1] < alphas[2])
        let expected = Double(GlassMenuMaterial.veil)
        #expect(abs(Double(alphas[1]) - expected) < 0.02)
    }

    /// Standard tooltip keeps the production panel's 4.5:1 fitted tint over
    /// its role glass, in each of the gallery's actual light and dark scopes.
    @Test(arguments: [1, 5])
    func standardTooltipKeepsContrastFittedTint(cardIndex: Int) throws {
        let card = TransientMaterialGallery.cards(for: .tooltip)[cardIndex]
        let surface = try #require(card.view.subviews.compactMap { $0 as? OverlaySurfaceView }.first)
        #expect(surface.tone.style == nil)
        #expect(!surface.isInteractive)
        let body = try #require(surface.contentView.subviews.first)
        let tint = try #require(body.subviews.first)
        let shown = try #require(tint.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        let fitted = TooltipSurface(card.view.themeTokens, lift: ChromeTunables.opaqueOverlayLift.value)
        #expect(abs(Double(shown.alphaComponent) - fitted.tint.alpha) < 0.01)
        #expect(TooltipSurface.worstContrast(ink: fitted.ink, tint: fitted.tint) >= ThemeTokens.minimumTextContrast)
    }

    /// A live adopted neutral surface changes its actual material when the
    /// accessibility setting changes, then returns to glass with its tone.
    @Test func selectedMaterialFollowsReduceTransparency() throws {
        let reduction = ReduceTransparency(system: { false }, changes: NotificationCenter())
        let selected = Glass.makeOverlayPanel(content: NSView(), tone: .neutralGlass(.transient))
        let style = try #require(selected.tone.style)
        let surface = OverlaySurfaceView(reduceTransparency: reduction, tone: .neutralGlass(style))
        #expect(surface.material != .opaque)
        reduction.override = true
        #expect(surface.material == .opaque)
        #expect(surface.rimView == nil)
        reduction.override = false
        #expect(surface.material != .opaque)
        #expect(surface.tone.style == style)
    }

    /// The existing native hover card is a non-chat caller of the selected
    /// material, rather than a fixture with a manually copied veil.
    @Test func hoverCardInheritsSelectedMaterial() throws {
        let card = HoverCardPanel()
        let style = try #require(card.glass.tone.style)
        #expect(style == .transient)
        #expect(card.glass.glassVariant == .picked)
    }
}
#endif
