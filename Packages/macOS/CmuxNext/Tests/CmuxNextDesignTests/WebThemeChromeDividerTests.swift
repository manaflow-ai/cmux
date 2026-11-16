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

    /// `tone` at contrast 1 on the flush corner (pinned in Debug Settings, so the assertions always run).
    private func with<T>(tone: TitleAreaTone, borders: BorderMode = .default, _ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let saved = (design.titleAreaTone, design.titleAreaContrast, design.borders)
        (design.titleAreaTone, design.titleAreaContrast, design.borders) = (tone, 1, borders)
        defer { (design.titleAreaTone, design.titleAreaContrast, design.borders) = saved }
        // Compact density keeps the pill before any override is read (`CornerFlush.current`): pin Default's.
        let density = DesignSettings.shared.densityTokens
        DesignSettings.shared.densityTokens = DensityPreset.cozy.tokens
        defer { DesignSettings.shared.densityTokens = density }
        let store = TunableStore.shared
        store.register([CornerFlush.tunable.descriptor])
        if !store.isActive { store.activate(file: nil) }
        let flush = store.set(CornerFlush.tunable.key, .choice(CornerFlush.goo.rawValue))
        defer { _ = store.set(CornerFlush.tunable.key, flush) }
        #expect(CornerFlush.current.isOn, "the pinned flush corner is off (compact density?)")
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
            #expect(vars["--cmux-chrome-tone"] == "0")
            #expect(vars["--cmux-folder-fill"] == "transparent")
        }
    }

    @Test func subtleToneTonesTheChromeAndFillsTheFolderWithThePage() {
        with(tone: .subtleTone) {
            let vars = variables
            let page = WebTheme.css(WebTheme.pageBackground(tokens, backgrounds: .none))
            #expect(vars["--cmux-chrome-divider"] == divider)
            #expect(vars["--cmux-chrome-tone"] == "1")
            #expect(vars["--cmux-folder-fill"] == page)
        }
    }

    /// A picked chrome style keeps its shade but draws pills, not folder tabs: a page's selected item is no folder
    /// tab there either, and with the tone but no folder there is never a tone without its fill.
    @Test func aPickedStyleIsNoFolderTabOnThePage() {
        let design = DesignSettings.shared
        let saved = design.chromeStyle
        defer { design.chromeStyle = saved }
        design.chromeStyle = .blocks
        let vars = WebTheme(tokens, backgrounds: .none).variables
        if !CornerFlush.current.isOn {
            #expect(vars["--cmux-chrome-tone"] == "0")
            #expect(vars["--cmux-folder-fill"] == "transparent")
        }
        #expect((vars["--cmux-chrome-tone"] == "1") == (vars["--cmux-folder-fill"] != "transparent"))
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
