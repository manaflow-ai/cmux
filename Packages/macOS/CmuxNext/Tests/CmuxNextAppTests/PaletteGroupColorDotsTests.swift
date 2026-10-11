import CmuxNextActions
import CmuxNextDesign
import CmuxNextPalette
import Testing

/// The palette's group color commands show the color they pick (cx-wqn5, theme balls): "Tab Group
/// Color: Red" draws the theme's red as a ball where the generic dot was, so the list reads like
/// the group editor's swatches and follows the terminal theme.
@MainActor
struct PaletteGroupColorDotsTests {
    @Test func groupColorCommandsDrawTheThemeColor() async {
        let items = await RegistryPaletteProvider(registry: .standard(), includeUnbound: true).items()
        let row = { (id: String) in items.first { $0.id == "action:\(id)" } }
        let tokens = ThemeScope.app.tokens
        for color in [GroupColor.red, .green, .orange] {
            for kind in ["tabGroup", "workspaceGroup"] {
                #expect(row("\(kind).color.\(color.rawValue)")?.swatches == color.themeRGB(tokens).map { [$0] })
            }
        }
        // None (grey) is the sidebar's neutral step, still a ball.
        #expect(row("tabGroup.color.grey")?.swatches.count == 1)
        // Other commands keep their symbol.
        #expect(row("tabGroup.create")?.swatches.isEmpty == true)
    }
}
