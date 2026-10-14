@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextTerminal
import CmuxTheme
import Foundation
import Testing

/// cmux's own themes (Resources/cmux-themes): the app's "Bundle Ghostty resources" phase puts them
/// next to Ghostty's themes, so every picker lists them and `theme = <name>` loads them. Fogline is
/// soft grey with a blue accent, Kiln warm neutral with a clay accent, each with a light pair. They
/// are options only: the default theme stays Apple System Colors.
@Suite struct BundledCmuxThemesTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Dark name to its light pair.
    static let pairs = ["Fogline": "Fogline Light", "Kiln": "Kiln Light"]

    /// Runs the app's bundle phase over the checked-in resources and returns the bundled
    /// Ghostty resources folder (what `GhosttyRuntime.resourcesDirectory()` finds in the app).
    static func bundle(into root: URL) throws -> String {
        let source = root.appending(path: "src/Resources")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for folder in ["ghostty", "cmux-themes"] where FileManager.default.fileExists(atPath: repoRoot.appending(path: "Resources/\(folder)").path) {
            try FileManager.default.createSymbolicLink(at: source.appending(path: folder),
                                                       withDestinationURL: repoRoot.appending(path: "Resources/\(folder)"))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repoRoot.appending(path: "scripts/cmux-next/bundle-ghostty-resources.sh").path]
        process.environment = ["PATH": "/usr/bin:/bin", "SRCROOT": root.appending(path: "src").path,
                               "TARGET_BUILD_DIR": root.appending(path: "build").path,
                               "UNLOCALIZED_RESOURCES_FOLDER_PATH": "app.app/Contents/Resources"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return root.appending(path: "build/app.app/Contents/Resources/ghostty").path
    }

    @Test func theBundledAppListsBothThemePairsAndTheirChromeMeetsTheContrastContract() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cnc-bundled-themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try Self.bundle(into: root)
        let home = root.appending(path: "home")
        let environment = ["XDG_CONFIG_HOME": root.appending(path: "config").path]

        let names = ThemeCatalog.list(resources: resources, home: home, environment: environment)
        let colors = ThemeCatalog.read(resources: resources, home: home, environment: environment).colors
        for (dark, light) in Self.pairs {
            for name in [dark, light] {
                #expect(names.contains(name), "\(name) is not in the bundled theme catalog")
                // Pinned in every theme picker and the context menus.
                #expect(ActionArgument.curatedThemes.contains(name))
            }
            guard let darkColors = colors[dark], let lightColors = colors[light] else {
                Issue.record("\(dark) or \(light) has no readable colors")
                continue
            }
            for (file, wantsDark) in [(darkColors, true), (lightColors, false)] {
                #expect(file.accent != nil, "\(file.name) names no accent")
                for accent in ThemeAccent.allCases {
                    let app = AppTheme.derive(background: file.background, foreground: file.foreground,
                                              palette: file.palette, accent: accent, accentColor: file.accent)
                    #expect(app.isDark == wantsDark, "\(file.name) isDark")
                    #expect(app.failures.isEmpty, "\(file.name) \(accent): \(app.failures)")
                }
            }
        }
        // Fogline's accent is blue, Kiln's clay (red over green over blue).
        let fogline = try #require(colors["Fogline"]?.accent)
        #expect(fogline.blue > fogline.red + 0.2 && fogline.blue > fogline.green + 0.1)
        let kiln = try #require(colors["Kiln"]?.accent)
        #expect(kiln.red > kiln.green && kiln.green > kiln.blue)
    }

    @Test func theDefaultThemeIsUnchangedAndNoGhosttyThemeIsReplaced() throws {
        #expect(GhosttyRuntime.defaultThemeSpec == "light:Apple System Colors Light,dark:Apple System Colors")
        #expect(ActionArgument.curatedThemes.first == "Rose Pine")
        let root = FileManager.default.temporaryDirectory.appending(path: "cnc-bundled-themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let themes = URL(fileURLWithPath: try Self.bundle(into: root)).appending(path: "themes")
        let shipped = Self.repoRoot.appending(path: "Resources/ghostty/themes")
        // Every Ghostty theme is bundled byte for byte, the default's pair included.
        for name in try FileManager.default.contentsOfDirectory(atPath: shipped.path) where !name.hasPrefix(".") {
            let expected = try Data(contentsOf: shipped.appending(path: name))
            let bundled = try? Data(contentsOf: themes.appending(path: name))
            #expect(bundled == expected, "\(name) changed in the bundle")
        }
        for name in [GhosttyRuntime.defaultDarkThemeName, GhosttyRuntime.defaultLightThemeName] {
            #expect(FileManager.default.fileExists(atPath: themes.appending(path: name).path))
        }
    }
}
