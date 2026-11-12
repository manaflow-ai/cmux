import CmuxTheme
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// The web half of the two-tone polish (Leo, 2026-11-12: "fixing up the whole, like, polish of the two-tone
/// mode"): pages draw the chrome's one divider (`--cmux-chrome-divider`, which the sidebar's line matches), know
/// whether the chrome is toned apart from the content (`--cmux-chrome-tone`) and fill a selected item as the
/// native folder tab does (`--cmux-folder-fill`), all from the page's own scope.
@MainActor @Suite(.serialized) struct WebThemeChromeDividerTests {
    private let tokens = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x101820), foreground: ThemeRGB(hex: 0xE8E8F0)))

    private func with<T>(tone: TitleAreaTone, borders: BorderMode = .default, _ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let saved = (design.titleAreaTone, design.titleAreaContrast, design.borders)
        (design.titleAreaTone, design.titleAreaContrast, design.borders) = (tone, 1, borders)
        defer { (design.titleAreaTone, design.titleAreaContrast, design.borders) = saved }
        return try body()
    }

    private var variables: [String: String] { WebTheme(tokens, backgrounds: .none).variables }

    /// `Palette.chromeDivider` for these tokens: the separator's alpha × `chrome.dividerStrength`, at most opaque.
    private var divider: String {
        let separator = tokens.separator
        return WebTheme.css(separator.withAlpha(min(1, separator.alpha * ChromeTunables.dividerStrength.value)))
    }

    @Test func oneColorDrawsTheChromeDividerAndNoTone() {
        with(tone: .oneColor) {
            let vars = variables
            #expect(vars["--cmux-chrome-divider"] == divider)
            #expect(vars["--cmux-sidebar-line"] == divider, "the sidebar's line is the native edge's, not the raw separator")
            let shade = Metrics.mainPaneChromeShade(isDark: tokens.isDark)
            #expect(vars["--cmux-chrome-tone"] == (shade > 0 ? "1" : "0"))
            guard CornerFlush.current.isOn else { return }
            #expect(vars["--cmux-chrome-tone"] == "0")
            #expect(vars["--cmux-folder-fill"] == "transparent")
        }
    }

    @Test func subtleToneTonesTheChromeAndFillsTheFolderWithThePage() {
        with(tone: .subtleTone) {
            let vars = variables
            let shade = Metrics.mainPaneChromeShade(isDark: tokens.isDark)
            let page = WebTheme.css(WebTheme.pageBackground(tokens, backgrounds: .none))
            #expect(vars["--cmux-chrome-tone"] == (shade > 0 ? "1" : "0"))
            #expect(vars["--cmux-folder-fill"] == (shade >= Metrics.folderTabMinimumShade ? page : "transparent"))
            #expect(vars["--cmux-chrome-divider"] == divider)
            guard CornerFlush.current.isOn else { return }
            #expect(vars["--cmux-chrome-tone"] == "1")
            #expect(vars["--cmux-folder-fill"] == page)
        }
    }

    @Test func bordersOffClearsTheDividers() {
        with(tone: .subtleTone, borders: .none) {
            #expect(variables["--cmux-chrome-divider"] == "transparent")
            #expect(variables["--cmux-sidebar-line"] == "transparent")
        }
    }

    /// A tone or strength change repaints every page (`AppServices.observeBorders` watches these inputs).
    @Test func theToneAndTheStrengthArePushInputs() {
        let one = with(tone: .oneColor) { WebTheme.pushInputs }
        let subtle = with(tone: .subtleTone) { WebTheme.pushInputs }
        #expect(one != subtle)
        #expect(one.contains("\(ChromeTunables.dividerStrength.value)"))
    }
}
