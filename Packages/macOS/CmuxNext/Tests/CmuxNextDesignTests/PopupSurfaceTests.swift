import AppKit
import CmuxNextTestSupport
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Leo, 2026-10-18: overlays that carry text (popovers, hover cards, the palette, the find bars)
/// are themed Liquid Glass, like iOS's menus, replacing the solid surface of 2026-10-12. Under
/// Reduce Transparency they are the one solid popup surface (the theme's opaque overlay fill), and
/// pages get the same color (`--cmux-popup-surface`) for their menus and tooltips.
@MainActor @Suite(.serialized, .closesItsWindows) struct PopupSurfaceTests {
    /// A see-through theme (60% background opacity): the window under a popup is translucent, the
    /// popup surface must not be.
    private let input = ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF),
                                   backgroundOpacity: 0.6)

    @Test func overlayPanelsFollowThisMacsMaterial() {
        let panel = Glass.makeOverlayPanel(content: NSTextField(labelWithString: "Find"))
        #expect(panel.materialOverride == nil)
        #expect(panel.material == OverlayMaterial.select(liquidGlassAvailable: Glass.isLiquidGlassAvailable,
                                                        reduceTransparency: ReduceTransparency.shared.isEnabled))
    }

    @Test func overlayPanelsAreTheOpaquePopupSurfaceUnderReduceTransparency() throws {
        let pinned = ReduceTransparency.shared.override
        ReduceTransparency.shared.override = true
        defer { ReduceTransparency.shared.override = pinned }
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Stress Purple")), input: input, animated: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let root = try #require(window.contentView)
        scope.root(root)
        let expected = scope.tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value).nsColor
        #expect(Self.same(scope.perform { Palette.popupSurface }, expected))

        // The palette's, a hover card's or popover's, and a find bar's.
        for radius in [Metrics.panelCornerRadius, PopupStyle.standard.cornerRadius, 6] {
            let panel = Glass.makeOverlayPanel(content: NSTextField(labelWithString: "Find"), cornerRadius: radius)
            panel.frame = NSRect(x: 10, y: 10, width: 200, height: 80)
            root.addSubview(panel)
            panel.applyTheme()
            #expect(panel.material == .opaque, "radius \(radius)")
            let fill = try #require(panel.subviews.first?.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
                                    "radius \(radius)")
            #expect(Self.same(fill, expected), "radius \(radius): \(fill) vs \(expected)")
            #expect(panel.subviews.first?.layer?.cornerRadius == radius)
            panel.removeFromSuperview()
        }
    }

    @Test func pagesGetTheSamePopupSurface() throws {
        let tokens = ThemeTokens.derive(from: input)
        let fill = tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value)
        #expect(fill.alpha == 1)
        let popup = try #require(WebTheme(tokens, surface: .internalPage, backgrounds: .none).variables["--cmux-popup-surface"])
        #expect(popup == WebTheme.css(fill))
    }

    /// Leo, 2026-10-12: on a light theme a popup 14% toward the text read as a dark gray box next to
    /// native near-white menus. Light themes lift toward white (a white page gets a white popup,
    /// set apart by its hairline and shadow), dark themes toward the text, and either way secondary
    /// text keeps 4.5:1 on a hovered row.
    @Test func popupsAreLighterThanThePageAndKeepSecondaryTextReadable() {
        let themes = [
            ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x000000)),
            ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F)),
            ThemeInput(background: ThemeRGB(hex: 0xFDF6E3), foreground: ThemeRGB(hex: 0x657B83)),
            ThemeInput(background: ThemeRGB(hex: 0xEEEEEE), foreground: ThemeRGB(hex: 0x333333)),
            ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4)),
            ThemeInput(background: ThemeRGB(hex: 0x282A36), foreground: ThemeRGB(hex: 0xF8F8F2)),
            ThemeInput(background: ThemeRGB(hex: 0x002B36), foreground: ThemeRGB(hex: 0x839496)),
            ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF)),
        ]
        for input in themes {
            let tokens = ThemeTokens.derive(from: input)
            let fill = tokens.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value)
            let page = tokens.windowBackground.withAlpha(1)
            #expect(fill.alpha == 1, "\(input.background)")
            if tokens.isDark {
                #expect(fill.relativeLuminance > page.relativeLuminance, "\(input.background): a lighter card")
            } else {
                #expect(fill.relativeLuminance >= page.relativeLuminance, "\(input.background): never a gray box")
            }
            let hovered = tokens.hoverFill.composited(over: fill)
            let contrast = tokens.textSecondary.withAlpha(1).contrast(with: hovered)
            #expect(contrast >= ThemeTokens.minimumTextContrast, "\(input.background): \(contrast)")
        }
        let white = ThemeTokens.derive(from: themes[0])
        #expect(white.opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value) == ThemeRGB(hex: 0xFFFFFF))
    }

    static func same(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.01 && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01 && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.01
    }
}
