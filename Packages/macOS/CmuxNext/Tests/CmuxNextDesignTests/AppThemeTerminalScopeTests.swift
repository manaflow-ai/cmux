@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// With an App Theme the chrome takes its colors, but a terminal without a theme of its own keeps the
/// terminal theme (the Ghostty config's colors), as its surface does. Its scope inherited the App
/// Theme instead, so in a see-through window (a background picture, glass, Opacity under 100%) the
/// terminal lost its own background: its text drew over the App Theme's tint (light text over a light
/// App Theme). A space or workspace theme still colors its terminals.
@MainActor @Suite struct AppThemeTerminalScopeTests {
    private let darkTerminal = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
    private let otherTerminal = ThemeInput(background: ThemeRGB(hex: 0x002B36), foreground: ThemeRGB(hex: 0x839496))
    private let lightApp = ThemeInput(background: ThemeRGB(hex: 0xFAF7F0), foreground: ThemeRGB(hex: 0x2B2A28))
    private let workspaceTheme = ThemeInput(background: ThemeRGB(hex: 0x282A36), foreground: ThemeRGB(hex: 0xF8F8F2))

    @Test func aTerminalKeepsTheTerminalThemeUnderAnAppTheme() throws {
        let store = ThemeStore()
        let app = ThemeScope(root: store)
        store.apply(darkTerminal)
        store.setAppTheme(from: lightApp)
        let room = ThemeScope(level: .room, parent: app)
        let workspace = ThemeScope(level: .workspace, parent: room)
        let terminal = ThemeScope(level: .terminal, parent: workspace)
        #expect(room.tokens == ThemeTokens.derive(from: lightApp))
        #expect(workspace.tokens == ThemeTokens.derive(from: lightApp))
        #expect(terminal.tokens == ThemeTokens.derive(from: darkTerminal))

        // A config reload (another terminal theme) reaches the terminal while the chrome holds.
        store.apply(otherTerminal)
        #expect(room.tokens == ThemeTokens.derive(from: lightApp))
        #expect(terminal.tokens == ThemeTokens.derive(from: otherTerminal))

        // A workspace theme colors its terminals.
        workspace.setOverride(try #require(ThemeSpec("Dracula")), input: workspaceTheme, animated: false)
        #expect(terminal.tokens == ThemeTokens.derive(from: workspaceTheme))
        workspace.setOverride(nil, input: nil, animated: false)
        #expect(terminal.tokens == ThemeTokens.derive(from: otherTerminal))

        // Match Terminal Theme: the chrome and the terminal draw the same colors again.
        store.setAppTheme(from: nil)
        #expect(room.tokens == ThemeTokens.derive(from: otherTerminal))
        #expect(terminal.tokens == ThemeTokens.derive(from: otherTerminal))
    }

    @Test func aTerminalMadeUnderAnAppThemeStartsOnTheTerminalTheme() {
        let store = ThemeStore()
        let app = ThemeScope(root: store)
        store.apply(darkTerminal)
        let terminal = ThemeScope(level: .terminal, parent: ThemeScope(level: .workspace, parent: app))
        store.setAppTheme(from: lightApp)
        #expect(terminal.tokens == ThemeTokens.derive(from: darkTerminal))
    }
}
