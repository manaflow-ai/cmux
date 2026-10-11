import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextPalette
import Testing

/// The palette's group color commands show the color they pick (cx-wqn5, theme balls): "Tab Group
/// Color: Red" draws the theme's red as a ball where the generic dot was, resolved by the row in
/// its theme scope, so the list reads like the group editors' swatches.
@MainActor
struct PaletteGroupColorBallsTests {
    @Test func groupColorCommandsDrawTheThemeColor() async throws {
        let items = await RegistryPaletteProvider(registry: .standard(), includeUnbound: true).items()
        let tokens = ThemeScope.app.tokens
        func drawn(_ id: String) throws -> [ThemeRGB] {
            let item = try #require(items.first { $0.id == "action:\(id)" })
            let cell = PaletteRowCell(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
            cell.configure(PaletteRow(item: item, highlights: [], score: 0), isSelected: false)
            return cell.swatch.isHidden ? [] : cell.swatch.colors
        }
        for color in [GroupColor.red, .green, .orange] {
            for kind in ["tabGroup", "workspaceGroup", "screen"] {
                let id = "\(kind).color.\(color.rawValue)"
                let got = try drawn(id), want = color.themeRGB(tokens).map { [$0] }
                #expect(got == want, "\(id): drew \(got), theme \(String(describing: want)), dark \(tokens.isDark), ansi \(tokens.ansi.count)")
            }
        }
        // Grey: a group's "none" is the sidebar's neutral step; a screen's grey is the mid grey it draws.
        #expect(try drawn("tabGroup.color.grey") != drawn("screen.color.grey"))
        #expect(try drawn("screen.color.grey").count == 1)
        // Other commands keep their symbol.
        #expect(try drawn("tabGroup.create").isEmpty)
    }
}
