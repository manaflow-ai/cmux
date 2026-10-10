import CmuxNextActions
import CmuxNextDesign
import CmuxNextPalette
import Testing

/// A suggested free-text argument (Set Theme) lists its pinned values, a row
/// for other text, then every known value, and typing searches them.
@MainActor @Suite struct PaletteThemeSuggestionTests {
    @Test func themePageListsEveryGhosttyThemeAndTakesOtherText() async throws {
        let registry = ActionRegistry.standard()
        var ran: [ActionInvocation] = []
        registry.bind("terminal.setTheme", invoke: { ran.append($0) })
        registry.argumentSuggestions = { _ in ["3024 Day", "Nord", "Zenburn"].map { ActionEnumCase(value: $0, title: $0) } }
        registry.argumentValidation = { _, text in text.hasPrefix("light:") }
        let controller = PaletteController(registry: registry, sources: MockPaletteData().sources, frecencyPersistence: nil)
        let model = controller.model
        model.reset(to: controller.commandsPage())
        model.query = "set terminal theme"
        await model.settle()
        model.handle(.submit)
        await model.settle()
        let titles = model.rows.map(\.item.title)
        // Pinned (config + onboarding's themes, Nord once), the pair row, then the rest.
        #expect(titles.first == "Use Ghostty Config")
        #expect(titles.filter { $0 == "Nord" }.count == 1)
        #expect(titles.contains("Light and Dark Pair…"))
        #expect(titles.suffix(2).elementsEqual(["3024 Day", "Zenburn"]))

        model.query = "zenb"
        await model.settle()
        #expect(model.rows.first?.item.title == "Zenburn")
        model.handle(.submit)
        #expect(ran.first?["theme"] == .string("Zenburn"))
    }

    /// Theme rows draw their swatch strip (R98) in the icon place; a value
    /// without colors (the Ghostty config, the pair row) keeps the symbol.
    @Test func themeRowsCarryTheirSwatchStrips() async throws {
        let registry = ActionRegistry.standard()
        registry.bind("terminal.setTheme", invoke: { _ in })
        registry.argumentSuggestions = { _ in ["Nord", "Zenburn"].map { ActionEnumCase(value: $0, title: $0) } }
        var sources = MockPaletteData().sources
        let nord = [ThemeRGB(hex: 0x2E3440), ThemeRGB(hex: 0xBF616A)]
        var asked: Set<String> = []
        sources.argumentSwatches = { source, value in
            asked.insert(source)
            return value == "Nord" ? nord : []
        }
        let controller = PaletteController(registry: registry, sources: sources, frecencyPersistence: nil)
        let model = controller.model
        model.reset(to: controller.commandsPage())
        model.query = "set terminal theme"
        await model.settle()
        model.handle(.submit)
        await model.settle()
        let rows = model.rows.map(\.item)
        #expect(rows.first { $0.title == "Nord" }?.swatches == nord)
        #expect(rows.first { $0.title == "Zenburn" }?.swatches == [])
        #expect(rows.first { $0.title == "Use Ghostty Config" }?.swatches == [])
        #expect(asked == [ActionSuggestions.ghosttyThemes])
    }
}
