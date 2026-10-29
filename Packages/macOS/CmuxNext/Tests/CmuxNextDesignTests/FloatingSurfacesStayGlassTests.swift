import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Leo, 2026-10-21, on his nightly: "WHY IS THIS SOLID COLOR AGAIN". The What's New popover beside
/// the Update Ready card, the session hover cards and the tab cards all show in the app's one hover
/// card window (`HoverCardPanel`), and the Update Ready card itself draws `CardSurfaceView`. Each is
/// glass in the shared material: the themed overlay glass (`OverlaySurfaceView`, Leo 2026-10-19,
/// #21785) or the shared neutral veil (`FloatingGlassStyle`). ccde782cb51 laid the mostly opaque
/// ``CardMaterial`` fill (at least 90%) over every theme-tone overlay, the hover card window's too,
/// which turned these surfaces back into solid cards. This fails when any layer between their
/// material and their content paints denser than the shared glass. Reduce Transparency (the
/// `.opaque` material) may be solid and is not checked here.
@MainActor @Suite(.serialized) struct FloatingSurfacesStayGlassTests {
    enum Look: String, CaseIterable { case light, dark }

    private func scope(_ look: Look) throws -> ThemeScope {
        let scope = ThemeScope(level: .room)
        let input = switch look {
        case .light: ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F))
        case .dark: ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
        }
        scope.setOverride(try #require(ThemeSpec("Stay Glass \(look.rawValue)")), input: input, animated: false)
        return scope
    }

    /// The densest shared glass: the neutral veils (`FloatingGlassStyle`) and the themed overlay
    /// tint (`Palette.glassTint` at `glassOverlayTintStrength`). Anything denser reads as a card
    /// painted over the glass.
    private static func sharedGlassCeiling(in scope: ThemeScope) -> CGFloat {
        let veils = [FloatingGlassStyle.toast, .dialog, .card, .agentTag].flatMap { [$0.darkVeilAlpha, $0.lightVeilAlpha] }
        let tint = scope.perform { Palette.glassTint }.alphaComponent
        let overlay = min(max(tint * ChromeTunables.glassOverlayTintStrength.value, 0), 1)
        return max(CGFloat(veils.max() ?? 0), overlay) + 0.01
    }

    /// Every fill drawn between `surface`'s material and its content, outermost first: a glass
    /// panel's tint (its private internals stand for it) and every layer fill on the way down,
    /// as `CardMaterialLegibilityTests` reads them.
    private static func fills(over surface: OverlaySurfaceView) -> [(String, CGFloat)] {
        var chain: [NSView] = []
        var current: NSView? = surface.contentView
        while let view = current, view !== surface {
            chain.append(view)
            current = view.superview
        }
        var out: [(String, CGFloat)] = []
        var skipUntil: NSView?
        for view in chain.reversed() {
            if let skip = skipUntil {
                guard view === skip else { continue }
                skipUntil = nil
            }
            if view === surface.contentView { break }
            if let glass = view as? GlassPanelView {
                if let tint = glass.tintColor { out.append(("glass tint", tint.alphaComponent)) }
                skipUntil = glass.contentView
                continue
            }
            if let color = view.layer?.backgroundColor, color.alpha > 0 { out.append(("\(type(of: view)) fill", color.alpha)) }
        }
        return out
    }

    /// The hover card window (session and tab cards, the Update Ready highlights) is the themed
    /// glass alone: no ``CardMaterial`` fill on it, on Liquid Glass or on the blur before macOS 26.
    @Test(arguments: Look.allCases)
    func theHoverCardWindowIsGlassNotASolidCard(look: Look) throws {
        let scope = try scope(look)
        let panel = HoverCardPanel()
        scope.adopt(panel)
        #expect(!panel.glass.isCard, "the hover card lays the opaque card fill on its glass")
        let ceiling = Self.sharedGlassCeiling(in: scope)
        for material in [OverlayMaterial.liquidGlass, .vibrancy] {
            panel.glass.materialOverride = material
            panel.themeDidChange()
            let fills = Self.fills(over: panel.glass)
            #expect(!fills.isEmpty, "\(look) \(material): no glass tint drawn")
            for (name, alpha) in fills {
                #expect(alpha <= ceiling, "\(look) \(material): \(name) at \(alpha), denser than the shared glass (\(ceiling))")
            }
        }
        panel.glass.materialOverride = nil
    }

    /// Every overlay made the shared way (the palette, popovers, menus, find and prompt bars) is the
    /// glass alone (Leo 2026-10-21: "STOP DOING SOLID. WE HAVE GLASS, SO JUST USE GLASS."): the
    /// card fill is opt-in, and no fill over the glass is denser than the shared glass.
    @Test(arguments: Look.allCases)
    func everyOverlayIsGlassByDefault(look: Look) throws {
        let scope = try scope(look)
        let ceiling = Self.sharedGlassCeiling(in: scope)
        for radius in [Metrics.panelCornerRadius, PopupStyle.standard.cornerRadius, 6] {
            let panel = Glass.makeOverlayPanel(content: NSView(), cornerRadius: radius)
            scope.root(panel)
            #expect(!panel.isCard, "radius \(radius): an overlay lays the opaque card fill on its glass")
            for material in [OverlayMaterial.liquidGlass, .vibrancy] {
                panel.materialOverride = material
                panel.applyTheme()
                for (name, alpha) in Self.fills(over: panel) {
                    #expect(alpha <= ceiling, "\(look) \(material) radius \(radius): \(name) at \(alpha)")
                }
            }
        }
    }

    /// The hover card gallery draws the card the way a hover shows it.
    @Test func theGalleryCardIsTheSameGlass() throws {
        let host = HoverCardGalleryHost(body: NSView(), recolor: {})
        let surface = try #require(host.subviews.compactMap { $0 as? OverlaySurfaceView }.first)
        #expect(!surface.isCard)
    }

    /// The sidebar's Update Ready card (and every sidebar card) draws the shared neutral veil, well
    /// below a solid fill, in light and dark.
    @Test(arguments: Look.allCases)
    func theUpdateReadyCardIsTheSharedVeil(look: Look) throws {
        let scope = try scope(look)
        let card = CardSurfaceView(reduceTransparency: ReduceTransparency(system: { false }, changes: NotificationCenter()))
        card.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
        scope.root(card)
        card.updateLayer()
        let fill = try #require(card.layer?.backgroundColor)
        let veil = FloatingGlassStyle.card.look(isDark: card.themeTokens.isDark).veil
        #expect(abs(fill.alpha - veil.alpha) < 0.02, "\(look): the card is not the shared veil (\(fill.alpha))")
        #expect(fill.alpha <= Self.sharedGlassCeiling(in: scope), "\(look): the card's fill is solid (\(fill.alpha))")
    }

    /// The check is not vacuous: a theme-tone overlay that keeps the card fill is denser than the
    /// shared glass on both materials, so the hover card test would catch it coming back.
    @Test(arguments: Look.allCases)
    func theCardFillTheHoverCardDropsIsSolid(look: Look) throws {
        let scope = try scope(look)
        let card = Glass.makeOverlayPanel(cornerRadius: HoverCardPanel.cornerRadius, cardFill: true)
        scope.root(card)
        #expect(card.isCard)
        let ceiling = Self.sharedGlassCeiling(in: scope)
        for material in [OverlayMaterial.liquidGlass, .vibrancy] {
            card.materialOverride = material
            card.applyTheme()
            let densest = Self.fills(over: card).map(\.1).max() ?? 0
            #expect(densest > ceiling, "\(look) \(material): the card fill (\(densest)) is no denser than the shared glass")
        }
    }
}
