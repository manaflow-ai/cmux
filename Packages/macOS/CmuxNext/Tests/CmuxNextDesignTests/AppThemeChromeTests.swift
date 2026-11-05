@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// `appearance.appTheme` colors the native chrome, not only the pages (a person reported "app theme
/// is not working": they picked a light App Theme and the sidebar, tab strips and titlebar stayed on
/// the dark terminal theme, because only `WebTheme` read it). With an app theme the store's tokens,
/// its light/dark and the input its scopes inherit are the app theme's; the Ghostty config's colors
/// (the terminal theme) stay in `configInput` for the terminals and the "Use Ghostty Config" swatch.
@MainActor @Suite struct AppThemeChromeTests {
    private let darkTerminal = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
    private let lightApp = ThemeInput(background: ThemeRGB(hex: 0xFAF7F0), foreground: ThemeRGB(hex: 0x2B2A28))

    @Test func anAppThemeColorsTheChrome() {
        let store = ThemeStore()
        store.apply(darkTerminal)
        #expect(store.tokens.isDark)

        #expect(store.setAppTheme(from: lightApp))
        #expect(!store.tokens.isDark)
        #expect(store.tokens == ThemeTokens.derive(from: lightApp))
        #expect(store.input == lightApp)
        #expect(store.appTheme == AppTheme.derive(from: lightApp))
        // The terminal theme is still the config's.
        #expect(store.configInput == darkTerminal)
    }

    @Test func aConfigReloadKeepsTheAppTheme() {
        let store = ThemeStore()
        store.apply(darkTerminal)
        store.setAppTheme(from: lightApp)
        let otherTerminal = ThemeInput(background: ThemeRGB(hex: 0x002B36), foreground: ThemeRGB(hex: 0x839496))
        store.apply(otherTerminal)
        #expect(store.tokens == ThemeTokens.derive(from: lightApp))
        #expect(store.configInput == otherTerminal)
    }

    @Test func matchTerminalThemeGoesBackToTheConfigColors() {
        let store = ThemeStore()
        store.apply(darkTerminal)
        store.setAppTheme(from: lightApp)
        #expect(store.setAppTheme(from: nil))
        #expect(store.tokens == ThemeTokens.derive(from: darkTerminal))
        #expect(store.appTheme == nil)
        #expect(!store.setAppTheme(from: nil))
    }

    @Test func theWindowBackgroundReachesBothThemes() {
        let store = ThemeStore()
        store.apply(darkTerminal)
        store.setAppTheme(from: lightApp)
        store.applyBackground(opacity: 0.6, blur: 20)
        #expect(store.configInput.backgroundOpacity == 0.6)
        #expect(store.input.backgroundOpacity == 0.6)
        #expect(store.input.backgroundBlur == 20)
        #expect(store.tokens.backgroundOpacity == 0.6)
    }

    @Test func theAccentReachesTheAppTheme() {
        let store = ThemeStore()
        store.apply(darkTerminal)
        store.setAppTheme(from: lightApp)
        store.setAccent(.blue)
        var accented = lightApp
        accented.accent = .blue
        #expect(store.tokens == ThemeTokens.derive(from: accented))
        #expect(store.appTheme == AppTheme.derive(from: accented))
    }
}
