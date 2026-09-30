import AppKit
import Foundation
import Testing
@testable import CmuxTerminalCore

/// Non-color settings must not opt an otherwise adaptive terminal out of Light mode.
@Suite struct GhosttyConfigAdaptiveAppearanceRegressionTests {
    @Test(arguments: [
        "font-size = 17",
        "font-family = Menlo",
        "keybind = ctrl+shift+r=reload_config",
        "background-opacity = 0.9",
        "working-directory = /tmp",
    ])
    func unrelatedSettingsPreserveAdaptiveColors(setting: String) throws {
        try withFixture(setting) { path, resources in
            let dark = load(path, resources: resources, scheme: .dark)
            let light = load(path, resources: resources, scheme: .light)

            #expect(dark.backgroundColor.hexString() == "#101112")
            #expect(dark.foregroundColor.hexString() == "#F0F1F2")
            #expect(light.backgroundColor.hexString() == "#FAFBFC")
            #expect(light.foregroundColor.hexString() == "#202122")
            if setting.hasPrefix("font-size") {
                #expect(dark.fontSize == 17)
                #expect(light.fontSize == 17)
            }
        }
    }

    @Test func includedNonColorSettingsPreserveAdaptiveColors() throws {
        try withFixture("config-file = fonts.conf") { path, resources in
            let included = URL(fileURLWithPath: path).deletingLastPathComponent()
                .appendingPathComponent("fonts.conf")
            try "font-size = 17\n".write(to: included, atomically: true, encoding: .utf8)
            let light = load(path, resources: resources, scheme: .light)
            #expect(light.backgroundColor.hexString() == "#FAFBFC")
            #expect(light.foregroundColor.hexString() == "#202122")
            #expect(light.fontSize == 17)
        }
    }

    @Test(arguments: ["background = #123456", "theme = Deliberate Dark"])
    func authoredAppearanceStillOwnsColors(setting: String) throws {
        try withFixture(setting) { path, resources in
            let light = load(path, resources: resources, scheme: .light)
            let dark = load(path, resources: resources, scheme: .dark)
            #expect(light.backgroundColor == dark.backgroundColor)
            #expect(light.foregroundColor == dark.foregroundColor)
            #expect(light.backgroundColor.hexString() == (setting.hasPrefix("theme") ? "#334455" : "#123456"))
        }
    }

    private func load(
        _ path: String,
        resources: URL,
        scheme: GhosttyConfig.ColorSchemePreference
    ) -> GhosttyConfig {
        var config = GhosttyConfig()
        config.loadResolvedUserConfig(
            configPaths: [path],
            preferredColorScheme: scheme,
            adaptiveDefaultThemeEnabled: true,
            environment: ["GHOSTTY_RESOURCES_DIR": resources.path],
            bundleResourceURL: nil
        )
        return config
    }

    private func withFixture(
        _ contents: String,
        body: (String, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-12797-\(UUID().uuidString)")
        let themes = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, contents) in [
            (GhosttyConfig.cmuxDefaultLightThemeName, "background = #fafbfc\nforeground = #202122\n"),
            (GhosttyConfig.cmuxDefaultDarkThemeName, "background = #101112\nforeground = #f0f1f2\n"),
        ] {
            try contents.write(to: themes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let path = root.appendingPathComponent("config.ghostty")
        let authoredTheme = root.appendingPathComponent("Deliberate Dark")
        try "background = #334455\nforeground = #ddeeff\n".write(
            to: authoredTheme, atomically: true, encoding: .utf8
        )
        try contents.replacingOccurrences(of: "Deliberate Dark", with: authoredTheme.path)
            .write(to: path, atomically: true, encoding: .utf8)
        try body(path.path, root)
    }
}
