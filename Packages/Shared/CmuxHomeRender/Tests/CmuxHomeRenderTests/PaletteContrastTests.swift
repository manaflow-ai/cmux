import CoreGraphics
import Testing
@testable import CmuxHomeRender

/// The composer and the labels around the transcript stay readable in light
/// and dark themes (user 2026-10-19: "the color of the input text, input,
/// and label ... looks dark"). Every text colour meets WCAG AA (4.5:1)
/// against the surface it is drawn on, in both bubble styles, key and
/// non-key, and a light theme's field is not a dark slab on a light page.
@MainActor
@Suite struct PaletteContrastTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let theme: HomePalette.Theme
        var testDescription: String { name }
    }

    nonisolated static let cases: [Case] = [
        Case(name: "light", theme: .init(background: .gray255(255), foreground: .gray255(29),
                                         accent: .rgb255(2, 132, 254), failure: .rgb255(215, 0, 21))),
        Case(name: "dark", theme: .init(background: .gray255(30), foreground: .gray255(230),
                                        accent: .rgb255(2, 132, 254), failure: .rgb255(255, 69, 58))),
        Case(name: "dracula", theme: .init(background: .rgb255(40, 42, 54), foreground: .rgb255(248, 248, 242),
                                           accent: .rgb255(189, 147, 249), failure: .rgb255(255, 85, 85))),
        // Solarized light: its own text is under 4.5:1 on its background.
        Case(name: "solarized-light", theme: .init(background: .rgb255(253, 246, 227), foreground: .rgb255(101, 123, 131),
                                                   accent: .rgb255(38, 139, 210), failure: .rgb255(220, 50, 47))),
    ]

    static func palettes(_ theme: HomePalette.Theme) -> [(String, HomePalette)] {
        [true, false].flatMap { active in
            [("iMessage active=\(active)", HomePalette.iMessageStyled(theme, active: active)),
             ("theme active=\(active)", HomePalette.themeStyled(theme, active: active))]
        }
    }

    /// The colour a viewer sees: `top` composited over an opaque `bottom`.
    static func over(_ top: HomeColor, _ bottom: HomeColor) -> HomeColor {
        let a = top.alpha
        return HomeColor(red: top.red * a + bottom.red * (1 - a), green: top.green * a + bottom.green * (1 - a),
                         blue: top.blue * a + bottom.blue * (1 - a))
    }

    static func ratio(_ a: HomeColor, _ b: HomeColor) -> Double {
        let la = a.relativeLuminance, lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test(arguments: cases) func composerTextIsReadable(_ c: Case) {
        for (style, p) in Self.palettes(c.theme) {
            let page = Self.over(p.background, c.theme.background)
            let field = Self.over(p.composeGlass, page)
            let typed = Self.ratio(Self.over(p.incomingText, field), field)
            let hint = Self.ratio(Self.over(p.placeholder, field), field)
            #expect(typed >= 4.5, "\(c.name) \(style): typed text \(typed):1 on the field")
            #expect(hint >= 4.5, "\(c.name) \(style): placeholder \(hint):1 on the field")
        }
    }

    @Test(arguments: cases) func labelsAreReadable(_ c: Case) {
        for (style, p) in Self.palettes(c.theme) {
            let page = Self.over(p.background, c.theme.background)
            let label = Self.ratio(Self.over(p.secondaryText, page), page)
            let chief = Self.ratio(p.incomingText, p.incomingBubble)
            #expect(label >= 4.5, "\(c.name) \(style): names, receipts and captions \(label):1 on the page")
            #expect(chief >= 4.5, "\(c.name) \(style): Chief bubble text \(chief):1")
        }
    }

    /// A light theme's field is the page or lighter (Messages' white field),
    /// never a grey slab darker than the page around it.
    @Test func lightFieldIsNotDarkerThanThePage() throws {
        let theme = try #require(Self.cases.first { $0.name == "light" }).theme
        for (style, p) in Self.palettes(theme) {
            let page = Self.over(p.background, theme.background)
            let field = Self.over(p.composeGlass, page)
            #expect(field.relativeLuminance >= page.relativeLuminance - 0.02, "light \(style): field darker than the page")
        }
    }

    /// WCAG 1.4.11: on a light theme the field is as pale as the page, so its
    /// edge is its boundary and meets 3:1 on the page (user 2026-10-25: "chief
    /// textbox contrast looks bad on light mode").
    @Test(arguments: cases.filter { $0.name == "light" || $0.name == "solarized-light" })
    func lightFieldEdgeMeetsNonTextContrast(_ c: Case) {
        for (style, p) in Self.palettes(c.theme) {
            let page = Self.over(p.background, c.theme.background)
            let edge = Self.over(p.composeStroke, page)
            let r = Self.ratio(edge, page)
            #expect(r >= HomePalette.minimumEdgeContrast, "\(c.name) \(style): field edge \(r):1 on the page")
        }
    }
}
