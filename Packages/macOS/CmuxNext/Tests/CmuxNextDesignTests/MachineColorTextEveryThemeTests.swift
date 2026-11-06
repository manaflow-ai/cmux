import CmuxTheme
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// User 2026-11-03: "we need to make sure every single theme, all the UI elements are colored
/// properly". A machine's name is drawn in its colour (the sidebar's priority rows, a workspace
/// hover card's host, a tab's machine badge), and that colour was the raw pick: a person's
/// `#FFFF00` read 1.1:1 on a light theme, `#000080` 1.6:1 on a dark one, and the automatic accents
/// only reached 3:1 on the bare sidebar. As text the colour keeps its hue and reads at 4.5:1 on the
/// bare, hovered, selected and pressed row, in every bundled theme (where no colour can, as Grass's
/// pressed row, as much as black or white reaches); a colour that already reads is kept as it is.
@MainActor @Suite struct MachineColorTextEveryThemeTests {
    static let picks = MachineColorOverrides(["yellow-box": "#FFFF00", "navy-box": "#000080", "grey-box": "#808080",
                                              "red-box": "#FF0000", "white-box": "#FFFFFF", "black-box": "#000000"])
    static let machines = ["yellow-box", "navy-box", "grey-box", "red-box", "white-box", "black-box",
                           "big-red", "mac-mini", "studio", "cloud-7", "laptop", "build-3", "dev-vm", "pi"]

    static func rows(_ tokens: ThemeTokens) -> [ThemeRGB] {
        let row = tokens.windowBackground.withAlpha(1)
        return [row, tokens.hoverFill.composited(over: row), tokens.selectionFill.composited(over: row), tokens.pressedFill.composited(over: row)]
    }

    @Test func aMachinesNameReadsInItsColorInEveryBundledTheme() throws {
        let themes = try CardNeverOpaqueTests.bundledThemes()
        #expect(themes.count > 600)
        var failures: [String] = []
        for theme in themes {
            let tokens = ThemeTokens.derive(from: theme.input)
            let rows = Self.rows(tokens)
            // 4.5:1, or where no colour reaches it on every row (Grass's pressed row), the most a pole reaches there.
            let bar = min(ThemeTokens.minimumTextContrast,
                          [ThemeRGB.white, .black].map { pole in rows.map { pole.contrast(with: $0) }.min() ?? 0 }.max() ?? 0)
            for name in Self.machines {
                let machine = MachineColor(name: name)
                let text = machine.textRGB(tokens: tokens, overrides: Self.picks, on: rows)
                for ground in rows where text.contrast(with: ground) < bar - 0.01 {
                    failures.append(String(format: "%@: %@ %.2f:1", theme.label, name, text.contrast(with: ground)))
                }
                let raw = machine.rgb(tokens: tokens, overrides: Self.picks)
                if rows.allSatisfy({ raw.contrast(with: $0) >= ThemeTokens.minimumTextContrast + 0.05 }) {
                    #expect(text == raw, "\(theme.label): \(name) already reads and must keep its colour")
                }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) failures; first:\n" + failures.prefix(60).joined(separator: "\n")))
    }
}
