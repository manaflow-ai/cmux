@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextTerminal
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// cmux's own themes (Resources/cmux-themes): the app's "Bundle Ghostty resources" phase puts them
/// next to Ghostty's themes, so every picker lists them and `theme = <name>` loads them. Soft Blue is
/// soft grey with a blue accent and Clay Orange warm neutral with a clay accent, each with a light
/// pair; Olive Grey is dark only and keeps the appearance accent. They are options only: the
/// default theme stays Apple System Colors.
@Suite(.closesItsWindows) struct BundledCmuxThemesTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Each theme and whether its chrome is dark.
    static let themes: [(name: String, isDark: Bool)] = [
        ("Soft Blue", true), ("Soft Blue Light", false),
        ("Clay Orange", true), ("Clay Orange Light", false),
        ("Olive Grey", true),
    ]

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

    @Test func theBundledAppListsEveryCmuxThemeAndItsChromeMeetsTheContrastContract() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cnc-bundled-themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try Self.bundle(into: root)
        let home = root.appending(path: "home")
        let environment = ["XDG_CONFIG_HOME": root.appending(path: "config").path]

        let names = ThemeCatalog.list(resources: resources, home: home, environment: environment)
        let colors = ThemeCatalog.read(resources: resources, home: home, environment: environment).colors
        for (name, wantsDark) in Self.themes {
            #expect(names.contains(name), "\(name) is not in the bundled theme catalog")
            // Pinned in every theme picker and the context menus.
            #expect(ActionArgument.curatedThemes.contains(name))
            guard let file = colors[name] else {
                Issue.record("\(name) has no readable colors")
                continue
            }
            for accent in ThemeAccent.allCases {
                let app = AppTheme.derive(background: file.background, foreground: file.foreground,
                                          palette: file.palette, accent: accent, accentColor: file.accent)
                #expect(app.isDark == wantsDark, "\(name) isDark")
                #expect(app.failures.isEmpty, "\(name) \(accent): \(app.failures)")
            }
        }
        // Soft Blue's accent is blue and Clay Orange's clay (red over green over blue), in both
        // modes. Olive Grey names none, so the appearance accent applies.
        for name in ["Soft Blue", "Soft Blue Light"] {
            let blue = try #require(colors[name]?.accent, "\(name) names no accent")
            #expect(blue.blue > blue.red + 0.2 && blue.blue > blue.green + 0.1)
        }
        for name in ["Clay Orange", "Clay Orange Light"] {
            let clay = try #require(colors[name]?.accent, "\(name) names no accent")
            #expect(clay.red > clay.green && clay.green > clay.blue)
        }
        #expect(colors["Olive Grey"]?.accent == nil)
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
        // The bundle phase never replaces a Ghostty theme, so a Ghostty theme with one of these
        // names would ship instead of cmux's: rename ours before taking such a release.
        for (name, _) in Self.themes {
            #expect(!FileManager.default.fileExists(atPath: shipped.appending(path: name).path), "Ghostty ships a theme named \(name)")
        }
        for name in [GhosttyRuntime.defaultDarkThemeName, GhosttyRuntime.defaultLightThemeName] {
            #expect(FileManager.default.fileExists(atPath: themes.appending(path: name).path))
        }
    }
}
