import Foundation
import Testing
@testable import CmuxFoundation

@Suite("Ghostty theme file colors")
struct GhosttyThemeColorsTests {
    @Test("Parses background, foreground, cursor and palette entries")
    func parsesThemeFile() {
        let colors = GhosttyThemeColors(parsing: """
        palette = 0=#45475a
        palette = 15 = #bac2de
        palette = 16=#ffffff
        background = #1e1e2e
        foreground = cdd6f4
        cursor-color = #f5e0dc
        # background = #ffffff
        selection-background = #585b70
        """)

        #expect(colors.background == GhosttyThemeRGB(red: 0x1E, green: 0x1E, blue: 0x2E))
        #expect(colors.foreground == GhosttyThemeRGB(red: 0xCD, green: 0xD6, blue: 0xF4))
        #expect(colors.cursor == GhosttyThemeRGB(red: 0xF5, green: 0xE0, blue: 0xDC))
        #expect(colors.palette[0] == GhosttyThemeRGB(red: 0x45, green: 0x47, blue: 0x5A))
        #expect(colors.palette[15] == GhosttyThemeRGB(red: 0xBA, green: 0xC2, blue: 0xDE))
        #expect(colors.palette.count == GhosttyThemeColors.ansiPaletteCount)
        #expect(colors.palette[1] == nil)
        #expect(colors.isDark == true)
    }

    @Test("Hex parsing accepts short form and rejects names")
    func parsesHex() {
        #expect(GhosttyThemeRGB(hex: "#fa0") == GhosttyThemeRGB(red: 0xFF, green: 0xAA, blue: 0x00))
        #expect(GhosttyThemeRGB(hex: "black") == nil)
        #expect(GhosttyThemeRGB(hex: "#12345") == nil)
    }

    @Test("A light background reads as light, a missing one as unknown")
    func classifiesAppearance() {
        #expect(GhosttyThemeColors(parsing: "background = #eff1f5").isDark == false)
        #expect(GhosttyThemeColors(parsing: "foreground = #000000").isDark == nil)
    }
}

@Suite("Ghostty theme catalog")
struct GhosttyThemeCatalogTests {
    @Test("Lists files by name, earlier directories winning a case-insensitive clash")
    func listsThemes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-theme-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user", isDirectory: true)
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundled.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "background = #000000".write(to: user.appendingPathComponent("nord"), atomically: true, encoding: .utf8)
        try "background = #ffffff".write(to: bundled.appendingPathComponent("Nord"), atomically: true, encoding: .utf8)
        try "".write(to: bundled.appendingPathComponent("Atom"), atomically: true, encoding: .utf8)

        let entries = GhosttyThemeCatalog(directories: [user, bundled, root.appendingPathComponent("missing")]).entries()
        #expect(entries.map(\.name) == ["Atom", "nord"])
        #expect(entries.last?.url.deletingLastPathComponent().lastPathComponent == "user")
    }
}

@Suite("Ghostty theme directories")
struct GhosttyThemeDirectoriesTests {
    @Test("Lists existing directories in lookup order, each once")
    func ordersDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-theme-dirs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        let bundled = root.appendingPathComponent("bundle/ghostty/themes", isDirectory: true)
        let xdg = root.appendingPathComponent("xdg", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let userThemes = home.appendingPathComponent(".config/ghostty/themes", isDirectory: true)
        for directory in [resources.appendingPathComponent("themes"), bundled, xdg.appendingPathComponent("ghostty/themes"), userThemes] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let urls = GhosttyThemeDirectories(
            environment: [
                "GHOSTTY_RESOURCES_DIR": resources.path,
                "XDG_DATA_DIRS": "\(xdg.path)::\(root.appendingPathComponent("missing").path)",
                "HOME": home.path,
            ],
            bundledThemeDirectories: [bundled, bundled, root.appendingPathComponent("absent")]
        ).urls

        let ours = urls.filter { $0.path.hasPrefix(root.standardizedFileURL.path) }
        #expect(ours == [
            resources.appendingPathComponent("themes", isDirectory: true),
            bundled,
            xdg.appendingPathComponent("ghostty/themes", isDirectory: true),
            userThemes,
        ].map(\.standardizedFileURL))
    }
}
