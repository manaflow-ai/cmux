@testable import CmuxNextApp
import CmuxNextDesign
import CmuxTheme
import Foundation
import Testing

/// Save as Ghostty Theme and Import Theme File (cx-wqn5.1): a theme with the user's edits becomes a
/// real Ghostty theme file in `~/.config/ghostty/themes`, and an imported file lands there too. Every
/// picker lists it after the catalog reloads. A theme file is Ghostty config, so only color keys are
/// written or copied (an imported `command =` never reaches Ghostty).
@Suite struct ThemeFileSaveTests {
    struct Folders {
        let root: URL
        var resources: String { root.appending(path: "resources").path }
        var environment: [String: String] { ["XDG_CONFIG_HOME": root.appending(path: "config").path] }
        var home: URL { root.appending(path: "home") }
        var user: URL { root.appending(path: "config/ghostty/themes") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "cnc-theme-files-\(UUID().uuidString)")
            let shipped = root.appending(path: "resources/themes")
            try FileManager.default.createDirectory(at: shipped, withIntermediateDirectories: true)
            try """
            palette = 0=#26233a
            palette = 4=#31748f
            background = #191724
            foreground = #e0def4
            cursor-color = #555169
            selection-background = #403d52
            selection-foreground = #e0def4
            """.write(to: shipped.appending(path: "Rose Pine"), atomically: true, encoding: .utf8)
        }

        func save(_ name: String, edits: [String: String], replace: Bool = false) throws -> URL {
            try GhosttyThemeFiles.save(name: name, base: "Rose Pine", edits: edits, resources: resources,
                                       home: home, environment: environment, replace: replace)
        }

        func importTheme(_ text: String, named name: String, replace: Bool = false) throws -> String {
            let file = root.appending(path: "download").appending(path: name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            return try GhosttyThemeFiles.importTheme(at: file, resources: resources, home: home,
                                                     environment: environment, replace: replace)
        }

        func catalog() -> (names: [String], colors: [String: ThemeFileColors]) {
            (ThemeCatalog.list(resources: resources, home: home, environment: environment),
             ThemeCatalog.read(resources: resources, home: home, environment: environment).colors)
        }
    }

    @Test func aSavedThemeIsTheBaseWithItsEditsAndEveryPickerListsIt() throws {
        let folders = try Folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let file = try folders.save("Rose Pine Ink", edits: ["background": "#101010", "4": "#88c0d0", "cursor": "#ffffff"])
        #expect(file == folders.user.appending(path: "Rose Pine Ink"))
        let text = try String(contentsOf: file, encoding: .utf8)
        // The edits replace the base's lines; the base's other colors stay.
        #expect(text.contains("background = #101010") && !text.contains("background = #191724"))
        #expect(text.contains("palette = 4=#88c0d0") && !text.contains("palette = 4=#31748f"))
        #expect(text.contains("cursor-color = #ffffff") && text.contains("palette = 0=#26233a"))
        #expect(text.contains("foreground = #e0def4") && text.contains("selection-foreground = #e0def4"))
        let catalog = folders.catalog()
        #expect(catalog.names.contains("Rose Pine Ink") && catalog.names.contains("Rose Pine"))
        #expect(catalog.colors["Rose Pine Ink"]?.background == ThemeRGB(hex: 0x101010))
    }

    @Test func aSaveRefusesABadNameAShippedNameAndAnExistingThemeUnlessReplacing() throws {
        let folders = try Folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        for name in ["", " ", ".hidden", "a/b", "x=y", "#1", "quote\"d", "light:a,dark:b"] {
            #expect(throws: GhosttyThemeFiles.Refusal.invalidName) { try folders.save(name, edits: [:]) }
        }
        #expect(throws: GhosttyThemeFiles.Refusal.shippedName) { try folders.save("Rose Pine", edits: [:]) }
        // The base is a theme name, never a path to another file.
        #expect(throws: GhosttyThemeFiles.Refusal.unknownBase) {
            try GhosttyThemeFiles.save(name: "Leak", base: "../../home/.ssh/config", edits: [:], resources: folders.resources,
                                       home: folders.home, environment: folders.environment, replace: false)
        }
        _ = try folders.save("Mine", edits: ["background": "#000000"])
        #expect(throws: GhosttyThemeFiles.Refusal.exists) { try folders.save("Mine", edits: ["background": "#111111"]) }
        _ = try folders.save("Mine", edits: ["background": "#222222"], replace: true)
        #expect(folders.catalog().colors["Mine"]?.background == ThemeRGB(hex: 0x222222))
    }

    @Test func anImportedFileKeepsOnlyItsColors() throws {
        let folders = try Folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let name = try folders.importTheme("""
        # Night Owl
        background = #011627
        foreground = #d6deeb
        palette = 1=#ef5350
        command = /bin/sh -c 'curl evil'
        config-file = /tmp/other
        """, named: "Night Owl")
        #expect(name == "Night Owl")
        let text = try String(contentsOf: folders.user.appending(path: "Night Owl"), encoding: .utf8)
        #expect(text.contains("background = #011627") && text.contains("palette = 1=#ef5350"))
        #expect(!text.contains("command") && !text.contains("config-file"))
        #expect(folders.catalog().names.contains("Night Owl"))
        #expect(throws: GhosttyThemeFiles.Refusal.notATheme) { try folders.importTheme("font-size = 14\n", named: "Fonts") }
        #expect(throws: GhosttyThemeFiles.Refusal.shippedName) { try folders.importTheme("background = #000000\n", named: "Rose Pine") }
        #expect(throws: GhosttyThemeFiles.Refusal.exists) { try folders.importTheme("background = #000000\n", named: "Night Owl") }
    }

    /// Leo, 2026-11-04: "Linux ricing and the whole dot file situation". A base16 scheme (the format
    /// most rices share) imports as a Ghostty theme with base16-shell's terminal mapping.
    @Test func aBase16SchemeImportsAsAGhosttyTheme() throws {
        let folders = try Folders()
        defer { try? FileManager.default.removeItem(at: folders.root) }
        let name = try folders.importTheme("""
        scheme: "Tomorrow Night"
        author: "Chris Kempson"
        base00: "1d1f21"
        base01: "282a2e"
        base02: "373b41"
        base03: "969896"
        base04: "b4b7b4"
        base05: "c5c8c6"
        base06: "e0e0e0"
        base07: "ffffff"
        base08: "cc6666"
        base09: "de935f"
        base0A: "f0c674"
        base0B: "b5bd68"
        base0C: "8abeb7"
        base0D: "81a2be"
        base0E: "b294bb"
        base0F: "a3685a"
        """, named: "tomorrow-night.yaml")
        #expect(name == "tomorrow-night")
        let text = try String(contentsOf: folders.user.appending(path: "tomorrow-night"), encoding: .utf8)
        for line in ["background = #1d1f21", "foreground = #c5c8c6", "cursor-color = #c5c8c6",
                     "selection-background = #373b41", "palette = 0=#1d1f21", "palette = 1=#cc6666",
                     "palette = 4=#81a2be", "palette = 8=#969896", "palette = 15=#ffffff"] {
            #expect(text.contains(line), "missing \(line)")
        }
        #expect(!text.contains("author"))
        #expect(folders.catalog().colors["tomorrow-night"]?.background == ThemeRGB(hex: 0x1d1f21))

        // The newer tinted-theming layout nests the colors under `palette:` with a `#`.
        let nested = try folders.importTheme("""
        system: "base16"
        name: "Nested"
        palette:
          base00: "#101010"
          base05: "#e0e0e0"
          base08: "#ff5555"
        """, named: "nested.yml")
        let nestedText = try String(contentsOf: folders.user.appending(path: nested), encoding: .utf8)
        #expect(nested == "nested")
        #expect(nestedText.contains("background = #101010") && nestedText.contains("palette = 1=#ff5555"))
        #expect(throws: GhosttyThemeFiles.Refusal.notATheme) {
            try folders.importTheme("scheme: \"Empty\"\nauthor: \"me\"\n", named: "empty.yaml")
        }
    }
}
