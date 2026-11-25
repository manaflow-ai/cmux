import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// "i dont want blurring/translucency personally" (Leo, 2026-11-23, ask-b744e845a2). The setting that
/// turns every blur and see-through window off is Plain Backgrounds (`ui.reducedBackgrounds`, off by
/// default). A theme change must never bring the blur back: with it on, every theme file cmux ships
/// (`Resources/theme-files`) and every look and app recipe (`cmux-customize-recipes`) draws an opaque,
/// unblurred window, even over a Ghostty config that asks for glass.
///
/// The themes that bring their own translucency to a person whose window is opaque and unblurred
/// (`backgroundBlur: "none"`, opacity 1) are pinned by name, so a theme edit that adds or drops glass,
/// frost or see-through fails here and has to say so in its diff.
@MainActor @Suite(.serialized) struct PlainBackgroundsEveryThemeTests {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every shipped theme file and recipe theme, by a theme-file name and its text.
    static func themes() throws -> [(name: String, text: String)] {
        let fm = FileManager.default
        var found: [(String, String)] = []
        let shipped = repo.appending(path: "Resources/theme-files")
        for file in try fm.contentsOfDirectory(atPath: shipped.path) where file.hasSuffix(".json") {
            found.append((String(file.dropLast(5)), try String(contentsOf: shipped.appending(path: file), encoding: .utf8)))
        }
        let recipes = repo.appending(path: "cmux-tui/crates/cmux-customize-recipes/recipes")
        let walker = try #require(fm.enumerator(atPath: recipes.path))
        for case let path as String in walker {
            let file = (path as NSString).lastPathComponent
            guard file.hasPrefix("theme"), file.hasSuffix(".json") else { continue }
            let name = "recipe-" + String(path.dropLast(5)).replacingOccurrences(of: "/", with: "-")
            found.append((name, try String(contentsOf: recipes.appending(path: path), encoding: .utf8)))
        }
        return found.sorted { $0.0 < $1.0 }
    }

    /// The window a theme draws over `config`, resolved over Ghostty's own `opacity` and `blur`.
    func window(theme: (name: String, text: String), config: String, ghosttyOpacity: Double,
                ghosttyBlur: Int) async throws -> (backgroundOpacity: Double, backgroundBlur: Int) {
        let home = try ThemeFileTests.Home()
        defer { withExtendedLifetime(home) {} }
        try home.write(theme.text, theme: theme.name)
        let settings = try ThemeFileTests.controller(home, config: config.replacingOccurrences(of: "THEME", with: theme.name))
        await settings.reload()
        #expect(ThemeFileSetting.name(in: settings.fileRoot) == theme.name)
        let drawn = ReducedBackgroundsSetting.drawn(settings.snapshot.windowBackground, reduced: settings.snapshot.reducedBackgrounds)
        return drawn.resolved(backgroundOpacity: ghosttyOpacity, backgroundBlur: ghosttyBlur)
    }

    @Test func thereAreThemesToCheck() throws {
        let names = try Self.themes().map(\.name)
        #expect(names.count >= 20, "\(names)")
        #expect(names.contains("lily-pond") && names.contains("recipe-looks-starry-night-theme"), "\(names)")
    }

    /// Plain Backgrounds on: no theme draws glass, frost or a see-through window, over a Ghostty
    /// config that asks for 70% Liquid Glass.
    @Test func plainBackgroundsKeepsEveryThemeOpaqueAndUnblurred() async throws {
        let config = #"{ "ui": { "reducedBackgrounds": true }, "appearance": { "themeFile": "THEME" } }"#
        for theme in try Self.themes() {
            let shown = try await window(theme: theme, config: config, ghosttyOpacity: 0.7, ghosttyBlur: -1)
            #expect(shown.backgroundOpacity == 1 && shown.backgroundBlur == 0,
                    "\(theme.name) draws \(shown) with Plain Backgrounds on")
        }
    }

    /// The themes that turn an opaque, unblurred window translucent. A change to this list is a
    /// change to what a theme switch does to a person who turned the blur off.
    static let translucentThemes: Set<String> = [
        "harbor", "lily-pond", "miku", "teal",
        "recipe-apps-lamina-mist-theme", "recipe-apps-lamina-mist-theme-light", "recipe-apps-lamina-theme",
        "recipe-apps-lamina-theme-light", "recipe-apps-lamina-tide-theme", "recipe-apps-lamina-tide-theme-light",
        "recipe-looks-aero-sky-theme", "recipe-looks-aurora-night-theme", "recipe-looks-deep-currents-theme",
        "recipe-looks-dot-grid-theme", "recipe-looks-engraving-theme", "recipe-looks-fuji-mist-theme",
        "recipe-looks-gilded-theme", "recipe-looks-hiroshige-dusk-theme", "recipe-looks-moonrise-theme",
        "recipe-looks-nio-guardian-theme", "recipe-looks-starry-night-theme", "recipe-looks-still-water-theme",
        "recipe-looks-ukiyo-e-theme", "recipe-looks-water-lilies-theme",
    ]

    @Test func onlyThePinnedThemesBringTheirOwnTranslucency() async throws {
        let config = #"{ "appearance": { "themeFile": "THEME", "backgroundOpacity": 1, "backgroundBlur": "none" } }"#
        var translucent: Set<String> = []
        for theme in try Self.themes() {
            let shown = try await window(theme: theme, config: config, ghosttyOpacity: 1, ghosttyBlur: 0)
            if shown.backgroundOpacity < 1 || shown.backgroundBlur != 0 { translucent.insert(theme.name) }
        }
        #expect(translucent == Self.translucentThemes,
                "now translucent: \(translucent.subtracting(Self.translucentThemes).sorted()); no longer: \(Self.translucentThemes.subtracting(translucent).sorted())")
    }
}
