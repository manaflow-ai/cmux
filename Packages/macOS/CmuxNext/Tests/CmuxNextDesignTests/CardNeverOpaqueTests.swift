import CmuxTheme
@testable import CmuxNextDesign
import Foundation
import Testing
import CmuxNextDesignTokens

/// Glass is never opaque, and card text keeps WCAG AA (Lawrence, 2026-10-20). Every floating
/// glass card (`Glass.makeOverlayPanel`) lays its ``CardMaterial`` fill on the glass at
/// `opacity`: the least alpha below 1 at which primary and secondary text keep 4.5:1 over black
/// and over white. When no alpha below 1 does, `opacity` falls back to exactly 1 and the glass
/// turns solid. This guards every theme cmux ships (Ghostty's bundled themes and cmux's own),
/// each in the mode (light or dark) its colors give it, against that fallback. Reduce
/// Transparency (`OverlayMaterial.opaque`) is allowed to be solid and is not checked here.
@MainActor @Suite struct CardNeverOpaqueTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The theme folders the app bundles (`scripts/cmux-next/bundle-ghostty-resources.sh`).
    static let themeFolders = ["Resources/ghostty/themes", "Resources/cmux-themes"]

    static let lift = ChromeTunables.opaqueOverlayLift.defaultValue

    struct BundledTheme {
        /// The folder of `themeFolders` the theme file is in.
        let folder: String
        let name: String
        let label: String
        let input: ThemeInput
        let tokens: ThemeTokens
        let card: CardMaterial
    }

    /// Grass (#13773D on #FFF0A5) is the one theme whose pressed and selected rows miss 4.5:1.
    /// No single ink reads on both its background and its pressed rows: white gets 5.62:1 on the
    /// background (and the card) but 4.41:1 on a pressed row; black gets 4.76:1 on a pressed row
    /// but 3.73:1 on the background, so the card would have to turn opaque. The ink choice takes
    /// white, the higher least contrast; the pressed row keeps 4.41:1.
    static let pressedRowExemptions: [String: Double] = ["Grass": 4.41]

    /// Every bundled theme with its tokens and card material at the shipped defaults.
    static func bundledThemes() throws -> [BundledTheme] {
        var themes: [BundledTheme] = []
        for folder in themeFolders {
            let directory = repoRoot.appending(path: folder)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { !$0.hasPrefix(".") }.sorted()
            for name in names {
                let text = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
                guard let colors = ThemeFileColors(name: name, themeFile: text) else { continue }
                let defaults = ThemeInput.ghosttyDefault.palette
                let palette = colors.palette.enumerated().map { $0.element ?? defaults[$0.offset] }
                var input = ThemeInput(background: colors.background, foreground: colors.foreground, palette: palette,
                                       selectionBackground: colors.selectionBackground,
                                       selectionForeground: colors.selectionForeground, cursor: colors.cursorColor)
                input.accentColor = colors.accent
                let tokens = ThemeTokens.derive(from: input)
                let card = CardMaterial(tokens, lift: lift, minimumOpacity: CardMaterial.defaultMinimumOpacity)
                themes.append(BundledTheme(folder: folder, name: name,
                                           label: "\(folder)/\(name) [\(tokens.isDark ? "dark" : "light")]",
                                           input: input, tokens: tokens, card: card))
            }
        }
        return themes
    }

    /// The labels of the cards that draw their fill at alpha 1: an opaque card on glass.
    static func opaqueCards(_ cards: [(label: String, card: CardMaterial)]) -> [String] {
        cards.filter { $0.card.opacity >= 1.0 }.map { "\($0.label) (fill \($0.card.fill), opacity \($0.card.opacity))" }
    }

    /// The strongest row fill text sits on (pressed or selected) over the background, as `derive` finds it.
    static func worstRowSurface(_ theme: BundledTheme) -> ThemeRGB {
        let bg = theme.input.background
        let fg = theme.input.foreground
        let rows = [theme.tokens.pressedFill, theme.tokens.selectionFill].map { $0.composited(over: bg) }
        return rows.min { fg.contrast(with: $0) < fg.contrast(with: $1) } ?? bg
    }

    static func close(_ a: ThemeRGB, _ b: ThemeRGB) -> Bool {
        abs(a.red - b.red) < 1e-9 && abs(a.green - b.green) < 1e-9 && abs(a.blue - b.blue) < 1e-9
    }

    /// The inks and card fill the rule before this change gave: the foreground walked toward
    /// white below 0.18 luminance of the row surface (black above) until it read on that row
    /// surface only, and a dark card fill always lifted toward the primary ink.
    static func previousRule(_ theme: BundledTheme) -> (primary: ThemeRGB, secondary: ThemeRGB, fill: ThemeRGB) {
        let bg = theme.input.background
        let fg = theme.input.foreground
        let row = worstRowSurface(theme)
        let minimum = ThemeTokens.minimumTextContrast
        var primary = fg
        if fg.contrast(with: row) < minimum {
            let pole: ThemeRGB = row.relativeLuminance < 0.18 ? .white : .black
            var step = 0.0
            while step < 1, primary.contrast(with: row) < minimum {
                step += 0.02
                primary = fg.mixed(toward: pole, step)
            }
        }
        var secondary = primary
        var fraction = 0.38
        while fraction > 0 {
            let candidate = primary.mixed(toward: bg, fraction)
            if candidate.contrast(with: row) >= minimum {
                secondary = candidate
                break
            }
            fraction -= 0.01
        }
        let page = theme.tokens.windowBackground.withAlpha(1)
        guard theme.tokens.isDark else { return (primary, secondary, page.mixed(toward: .white, lift)) }
        var step = (lift * 100).rounded() / 100
        while step > 0 {
            let fill = page.mixed(toward: primary.withAlpha(1), step)
            if secondary.withAlpha(1).contrast(with: theme.tokens.hoverFill.composited(over: fill)) >= minimum {
                return (primary, secondary, fill)
            }
            step -= 0.01
        }
        return (primary, secondary, page)
    }

    @Test func everyBundledThemeKeepsItsCardGlassTranslucentAndItsCardTextAA() throws {
        let themes = try Self.bundledThemes()
        // Hundreds of Ghostty themes plus cmux's own: an empty read would check nothing.
        #expect(themes.count > 500, "read only \(themes.count) bundled themes")
        let opaque = Self.opaqueCards(themes.map { (label: $0.label, card: $0.card) })
        #expect(opaque.isEmpty, "card glass is opaque (no alpha below 1 keeps AA) in \(opaque.count) themes:\n\(opaque.joined(separator: "\n"))")
        var cardInk: [String] = []
        var rowInk: [String] = []
        for theme in themes {
            let row = Self.worstRowSurface(theme)
            for (role, ink) in [("primary", theme.tokens.textPrimary), ("secondary", theme.tokens.textSecondary)] {
                let onCard = TooltipSurface.worstContrast(ink: ink.withAlpha(1), tint: theme.card.tint)
                if onCard < ThemeTokens.minimumTextContrast { cardInk.append("\(theme.label) \(role) \(onCard)") }
                let onRow = ink.withAlpha(1).contrast(with: row)
                if let floor = Self.pressedRowExemptions[theme.name] {
                    #expect(abs(onRow - floor) < 0.01, "\(theme.label) \(role): pressed row \(onRow), exempted at \(floor)")
                } else if onRow < ThemeTokens.minimumTextContrast {
                    rowInk.append("\(theme.label) \(role) \(onRow)")
                }
            }
        }
        #expect(cardInk.isEmpty, "card text under 4.5:1 in \(cardInk.count) cases:\n\(cardInk.joined(separator: "\n"))")
        #expect(rowInk.isEmpty, "pressed-row text under 4.5:1 in \(rowInk.count) cases:\n\(rowInk.joined(separator: "\n"))")
    }

    /// The ink choice changes exactly Grass (ink, and so its lifted card fill) and Hot Dog Stand
    /// (ink and the white-lifted card fill); every other bundled theme keeps what it had.
    @Test func onlyGrassAndHotDogStandChange() throws {
        var changed: [String: [String]] = [:]
        for theme in try Self.bundledThemes() {
            let before = Self.previousRule(theme)
            var parts: [String] = []
            if !Self.close(before.primary, theme.tokens.textPrimary) || !Self.close(before.secondary, theme.tokens.textSecondary) {
                parts.append("ink")
            }
            if !Self.close(before.fill, theme.tokens.opaqueOverlayFill(lift: Self.lift)) { parts.append("fill") }
            if !parts.isEmpty { changed[theme.name] = parts }
        }
        #expect(changed == ["Grass": ["ink", "fill"], "Hot Dog Stand": ["ink", "fill"]], "changed: \(changed)")
    }

    /// The ink choice takes whichever of the light and the dark ink keeps the higher least
    /// contrast over the background and the pressed row: light on Grass, dark on Hot Dog Stand.
    @Test func theInkChoiceTakesTheHigherLeastContrast() {
        let grassBackground = ThemeRGB(hex: 0x13773D)
        let grass = ThemeTokens.derive(from: ThemeInput(background: grassBackground, foreground: ThemeRGB(hex: 0xFFF0A5)))
        #expect(grass.textPrimary.relativeLuminance > grassBackground.relativeLuminance, "Grass: \(grass.textPrimary) is not the light ink")
        let grassRatio = grass.textPrimary.contrast(with: grassBackground)
        #expect(abs(grassRatio - 5.62) < 0.01, "Grass: primary \(grassRatio) on the background")

        let hotDogBackground = ThemeRGB(hex: 0xEA3323)
        let hotDog = ThemeTokens.derive(from: ThemeInput(background: hotDogBackground, foreground: ThemeRGB(hex: 0xFFFFFF)))
        #expect(hotDog.textPrimary.relativeLuminance < hotDogBackground.relativeLuminance, "Hot Dog Stand: \(hotDog.textPrimary) is not the dark ink")
        for (role, ink) in [("primary", hotDog.textPrimary), ("secondary", hotDog.textSecondary)] {
            let ratio = ink.contrast(with: hotDogBackground)
            #expect(ratio >= ThemeTokens.minimumTextContrast, "Hot Dog Stand: \(role) \(ratio) on the background")
        }
        // White, the theme's own foreground, only reaches 4.20:1 on the background.
        #expect(abs(ThemeRGB.white.contrast(with: hotDogBackground) - 4.20) < 0.01)
    }

    /// A dark theme whose chosen ink is darker than its page lifts the card fill toward white,
    /// as a light theme does: lifting toward the dark ink would darken the card under it.
    @Test func aDarkInkOnADarkThemeLiftsTheCardTowardWhite() {
        let hotDog = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0xEA3323), foreground: ThemeRGB(hex: 0xFFFFFF)))
        #expect(hotDog.isDark)
        let page = hotDog.windowBackground.withAlpha(1)
        #expect(Self.close(hotDog.opaqueOverlayFill(lift: Self.lift), page.mixed(toward: .white, Self.lift)))
        let card = CardMaterial(hotDog, lift: Self.lift)
        #expect(card.opacity < 1.0)
    }

    /// The checker reports a card whose text cannot reach AA below alpha 1, so the theme sweep
    /// cannot pass by checking nothing.
    @Test func theCheckerReportsACardThatOnlyAnOpaqueFillKeepsLegible() {
        // Grey ink on a grey fill: no alpha keeps 4.5:1, so the fill falls back to 1.
        let stuck = CardMaterial(fill: ThemeRGB(hex: 0x808080), inks: [ThemeRGB(hex: 0x8C8C8C)],
                                 minimumOpacity: CardMaterial.defaultMinimumOpacity, isDark: false)
        // Near-black ink on white keeps AA at the least opacity.
        let fine = CardMaterial(fill: ThemeRGB(hex: 0xFFFFFF), inks: [ThemeRGB(hex: 0x111111)],
                                minimumOpacity: CardMaterial.defaultMinimumOpacity, isDark: false)
        #expect(stuck.opacity == 1.0)
        #expect(fine.opacity < 1.0)
        let opaque = Self.opaqueCards([(label: "stuck", card: stuck), (label: "fine", card: fine)])
        #expect(opaque.count == 1)
        #expect(opaque.first?.hasPrefix("stuck") == true)
    }
}
