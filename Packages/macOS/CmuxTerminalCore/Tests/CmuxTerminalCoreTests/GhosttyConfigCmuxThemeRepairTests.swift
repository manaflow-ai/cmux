import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite struct GhosttyConfigCmuxThemeRepairTests {
    @Test func repairsLightOnlyManagedTheme() {
        let contents = """
        font-family = Mono
        # cmux themes start
        theme = light:Solarized Light
        # cmux themes end
        """

        #expect(
            GhosttyConfig.normalizedCmuxManagedThemeValue(in: contents)
                == "light:Solarized Light,dark:Solarized Light"
        )
    }

    @Test func repairsDarkOnlyManagedTheme() {
        let contents = """
        # cmux themes start
        theme = dark:Tokyo Night
        # cmux themes end
        """

        #expect(
            GhosttyConfig.normalizedCmuxManagedThemeValue(in: contents)
                == "light:Tokyo Night,dark:Tokyo Night"
        )
    }

    @Test(arguments: [
        "theme = Solarized Light",
        "theme = light:Solarized Light,dark:Tokyo Night",
        "theme = light:Solarized Light,dark:Tokyo Night\n# cmux themes end\n# cmux themes start\ntheme = Tokyo Night",
    ])
    func leavesNonSingleSidedValuesUnchanged(_ themeDirective: String) {
        let contents = """
        # cmux themes start
        \(themeDirective)
        # cmux themes end
        """

        #expect(GhosttyConfig.normalizedCmuxManagedThemeValue(in: contents) == nil)
    }

    @Test func ignoresUnmarkedSingleSidedTheme() {
        #expect(
            GhosttyConfig.normalizedCmuxManagedThemeValue(
                in: "theme = light:Solarized Light"
            ) == nil
        )
    }

    @Test func resolvedConfigUsesRepairedManagedThemePair() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-theme-repair-(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: path) }
        try """
        # cmux themes start
        theme = light:Solarized Light
        # cmux themes end
        """.write(to: path, atomically: true, encoding: .utf8)

        var config = GhosttyConfig()
        config.loadResolvedUserConfig(
            configPaths: [path.path],
            preferredColorScheme: .light,
            environment: [:],
            bundleResourceURL: nil
        )

        #expect(config.theme == "light:Solarized Light,dark:Solarized Light")
    }
}
