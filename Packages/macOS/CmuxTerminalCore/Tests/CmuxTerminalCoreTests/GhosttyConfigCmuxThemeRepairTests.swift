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

    @Test(arguments: ["User Theme", "dark:User Theme", "light:Legacy Theme", "\"\""])
    func laterUnmarkedThemeKeepsPrecedenceOverRepairedManagedTheme(_ userTheme: String) throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-theme-repair-later-theme-\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: path) }
        let contents = """
        # cmux themes start
        theme = light:Legacy Theme
        # cmux themes end
        theme = \(userTheme)
        """
        try contents.write(to: path, atomically: true, encoding: .utf8)

        // The embedded Ghostty loader uses this shared result directly.
        #expect(GhosttyConfig.normalizedCmuxManagedThemeValue(in: contents) == nil)

        var config = GhosttyConfig()
        config.loadResolvedUserConfig(
            configPaths: [path.path],
            preferredColorScheme: .light,
            environment: [:],
            bundleResourceURL: nil
        )

        #expect(config.theme == userTheme.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }

    @Test func repairsManagedThemeWhenFileStartsWithUTF8BOM() {
        let contents = "\u{FEFF}  # cmux themes start\n"
            + "theme = light:Solarized Light\n"
            + "# cmux themes end\n"

        #expect(
            GhosttyConfig.normalizedCmuxManagedThemeValue(in: contents)
                == "light:Solarized Light,dark:Solarized Light"
        )
    }

    @Test(arguments: ["light", "dark"])
    func conditionalOverrideRepairsTheMissingManagedAppearance(_ side: String) throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-theme-repair-override-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: path) }
        let contents = """
        # cmux themes start
        theme = \(side):Legacy Theme
        # cmux themes end
        """
        try contents.write(to: path, atomically: true, encoding: .utf8)
        let preferredColorScheme: GhosttyConfig.ColorSchemePreference = side == "light" ? .dark : .light

        #expect(GhosttyConfig.userAppearanceConfigSummary(configPaths: [path.path]).lastThemeDirective
            == "light:Legacy Theme,dark:Legacy Theme")
        #expect(GhosttyConfigDiscovery().conditionalThemeOverrideConfigContents(
            preferredColorScheme: preferredColorScheme,
            configPaths: [path.path]
        ) == "theme = Legacy Theme")
        #expect(try String(contentsOf: path, encoding: .utf8) == contents)
    }

    @Test(arguments: ["same-file", "later-file", "included-file"])
    func conditionalOverridePreservesLaterUnmarkedDirective(_ location: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-theme-repair-override-precedence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rootPath = directory.appendingPathComponent("config")
        let userPath = directory.appendingPathComponent("user.conf")
        try "theme = light:Legacy Theme".write(to: userPath, atomically: true, encoding: .utf8)
        var contents = """
        # cmux themes start
        theme = light:Legacy Theme
        # cmux themes end
        """
        var configPaths = [rootPath.path]
        switch location {
        case "same-file":
            contents += "\ntheme = light:Legacy Theme"
        case "later-file":
            configPaths.append(userPath.path)
        default:
            contents += "\nconfig-file = \(userPath.path)"
        }
        try contents.write(to: rootPath, atomically: true, encoding: .utf8)

        #expect(GhosttyConfig.userAppearanceConfigSummary(configPaths: configPaths).lastThemeDirective
            == "light:Legacy Theme")
        #expect(GhosttyConfigDiscovery().conditionalThemeOverrideConfigContents(
            preferredColorScheme: .dark,
            configPaths: configPaths
        ) == nil)
    }
}
