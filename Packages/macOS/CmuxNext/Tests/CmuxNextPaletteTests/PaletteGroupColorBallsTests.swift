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
        // Each row sits in a room with its own palette, unlike the app theme's, so the ball must
        // come from the scope the row draws in.
        let scope = ThemeScope(level: .room)
        let palette = [0x1A1A1A, 0xE0533D, 0x3FB950, 0xD29922, 0x3B82F6, 0xA371F7, 0x2DD4BF, 0xC9D1D9]
        let input = ThemeInput(background: ThemeRGB(hex: 0x0E1116), foreground: ThemeRGB(hex: 0xE6EDF3),
                               palette: palette.map { ThemeRGB(hex: UInt32($0)) })
        scope.setOverride(try #require(ThemeSpec("Ball Room")), input: input, animated: false)
        let tokens = scope.tokens
        func drawn(_ id: String) throws -> [ThemeRGB] {
            let item = try #require(items.first { $0.id == "action:\(id)" })
            let cell = PaletteRowCell(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
            scope.root(cell)
            cell.configure(PaletteRow(item: item, highlights: [], score: 0), isSelected: false)
            return cell.swatch.isHidden ? [] : cell.swatch.colors
        }
        #expect(GroupColor.red.themeRGB(tokens) != GroupColor.red.themeRGB(ThemeScope.app.tokens))
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
