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
            .appendingPathComponent("cmux-theme-repair-\(UUID().uuidString)", isDirectory: false)
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

    @Test func includedUserThemeKeepsPrecedenceOverRepairedManagedTheme() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-theme-repair-include-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let includedPath = directory.appendingPathComponent("included.conf", isDirectory: false)
        try "theme = Included Theme\n".write(
            to: includedPath,
            atomically: true,
            encoding: .utf8
        )
        let rootPath = directory.appendingPathComponent("config", isDirectory: false)
        try """
        # cmux themes start
        theme = light:Legacy Theme
        # cmux themes end
        config-file = \(includedPath.path)
        """.write(to: rootPath, atomically: true, encoding: .utf8)

        var config = GhosttyConfig()
        config.loadResolvedUserConfig(
            configPaths: [rootPath.path],
            preferredColorScheme: .light,
            environment: [:],
            bundleResourceURL: nil
        )

        #expect(config.theme == "Included Theme")
    }
}
