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
    private let lowContrast = ThemeInput(background: ThemeRGB(hex: 0x000000), foreground: ThemeRGB(hex: 0x777777))

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

    @Test func highContrastRaisesChromeTextAndResetsToTheDefault() {
        let store = ThemeStore(input: lowContrast)
        #expect(store.contrastFloor == ThemeTokens.minimumTextContrast)
        #expect(store.tokens == ThemeTokens.derive(from: lowContrast))
        #expect(store.setContrastFloor(7))
        #expect(store.contrastFloor == 7)
        #expect(store.tokens == ThemeTokens.derive(from: lowContrast, contrastFloor: 7))
        #expect(store.tokens.textPrimary.contrast(with: lowContrast.background) >= 7)
        #expect(store.tokens.textSecondary.contrast(with: lowContrast.background) >= 7)
        #expect(store.setContrastFloor(ThemeTokens.minimumTextContrast))
        #expect(store.contrastFloor == ThemeTokens.minimumTextContrast)
        #expect(store.tokens == ThemeTokens.derive(from: lowContrast))
    }

    @Test func highContrastReachesInheritedThemeScopes() {
        let store = ThemeStore(input: lowContrast)
        let app = ThemeScope(root: store)
        let room = ThemeScope(level: .room, parent: app)
        #expect(room.tokens == ThemeTokens.derive(from: lowContrast))
        store.setContrastFloor(7)
        #expect(room.tokens == ThemeTokens.derive(from: lowContrast, contrastFloor: 7))
        #expect(room.tokens.textSecondary.contrast(with: lowContrast.background) >= 7)
    }

    @Test func anOverrideUpdatesEvenWhenTheRootAlreadyMeetsTheFloor() throws {
        let store = ThemeStore(input: ThemeInput(background: .white, foreground: .black, backgroundOpacity: 0.1))
        let app = ThemeScope(root: store)
        let room = ThemeScope(level: .room, parent: app)
        room.setOverride(try #require(ThemeSpec("Dracula")), input: lowContrast, animated: false)
        let before = store.tokens
        store.setContrastFloor(7)
        #expect(store.tokens == before)
        #expect(room.tokens == ThemeTokens.derive(from: lowContrast, contrastFloor: 7))
        let terminal = ThemeScope(level: .terminal, parent: room)
        #expect(terminal.tokens == room.tokens)
        store.setContrastFloor(ThemeTokens.minimumTextContrast)
        #expect(room.tokens == ThemeTokens.derive(from: lowContrast))
        #expect(terminal.tokens == room.tokens)
    }

}
