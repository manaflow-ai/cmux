import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextPalette
import Testing

/// The palette's group color commands show the color they pick (cx-wqn5): "Tab Group Color: Red"
/// draws the group palette's red as a ball where the generic dot was, resolved by the row in its
/// theme scope (its light or dark variant), so the list reads like the group editors' swatches.
@MainActor
struct PaletteGroupColorBallsTests {
    @Test func groupColorCommandsDrawTheGroupPalette() async throws {
        let items = await RegistryPaletteProvider(registry: .standard(), includeUnbound: true).items()
        // Each row sits in a room with its own palette, unlike the app theme's: the ball is the
        // group palette's color, never the room's ANSI color.
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
        for color in [GroupColor.red, .green, .orange] {
            for kind in ["tabGroup", "workspaceGroup", "screen"] {
                let id = "\(kind).color.\(color.rawValue)"
                let got = try drawn(id), want = [color.rgb(.swatch, dark: tokens.isDark)]
                #expect(got == want, "\(id): drew \(got), want \(want), dark \(tokens.isDark)")
                #expect(got != color.themeRGB(tokens).map { [$0] }, "\(id) drew the room's ANSI color")
            }
        }
        // Grey: a group's and a screen's both draw the palette's grey.
        let grey = [GroupColor.grey.rgb(.swatch, dark: tokens.isDark)]
        #expect(try drawn("tabGroup.color.grey") == grey)
        #expect(try drawn("screen.color.grey") == grey)
        // Other commands keep their symbol.
        #expect(try drawn("tabGroup.create").isEmpty)
    }
}
