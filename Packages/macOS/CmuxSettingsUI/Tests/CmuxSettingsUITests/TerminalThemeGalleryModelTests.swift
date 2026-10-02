import CmuxFoundation
import Foundation
import Testing
@testable import CmuxSettingsUI

/// Picking, previewing and reverting in the Settings terminal theme gallery,
/// against a real temporary config file.
@MainActor
@Suite("Terminal theme gallery model")
struct TerminalThemeGalleryModelTests {
    private final class ReloadLog {
        var phases: [TerminalThemeReloadPhase] = []
    }

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-theme-gallery-\(UUID().uuidString)", isDirectory: true)

    private func makeModel(
        existingConfig: String?,
        currentThemeValue: String?,
        prefersDark: Bool = false,
        themeDirectories: [URL] = []
    ) throws -> (TerminalThemeGalleryModel, CmuxManagedThemeConfigFile, ReloadLog) {
        let file = CmuxManagedThemeConfigFile(url: root.appendingPathComponent("config.ghostty"))
        if let existingConfig {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try existingConfig.write(to: file.url, atomically: true, encoding: .utf8)
        }
        let log = ReloadLog()
        let model = TerminalThemeGalleryModel(
            context: TerminalThemeGalleryContext(
                configFile: file,
                themeDirectories: themeDirectories,
                readCurrentThemeValue: { currentThemeValue },
                prefersDarkAppearance: prefersDark
            ),
            reload: { log.phases.append($0) }
        )
        return (model, file, log)
    }

    @Test("A pick writes the managed block, keeps user lines, and previews")
    func pickWritesBlock() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, file, log) = try makeModel(
            existingConfig: "font-size = 13\n",
            currentThemeValue: "light:Catppuccin Latte,dark:Catppuccin Mocha",
            prefersDark: true
        )
        #expect(model.themeInUse == "Catppuccin Mocha")

        model.select("Nord")

        #expect(model.selection == CmuxTerminalThemePair(light: "Nord", dark: "Nord"))
        #expect(model.themeInUse == "Nord")
        #expect(try file.readContents() == """
        font-size = 13

        # cmux themes start
        theme = light:Nord,dark:Nord
        # cmux themes end

        """)
        #expect(log.phases == [.preview])
        #expect(model.hasPendingChange)
    }

    @Test("The highlighted card is the theme the terminal shows, even from a pair")
    func highlightedThemeIsThemeInUse() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // A pair written by `cmux themes set --light/--dark`, whose light side
        // is a dark theme: the terminal shows the dark side in dark mode.
        let (model, _, _) = try makeModel(
            existingConfig: nil,
            currentThemeValue: "light:Front End Delight,dark:Iceberg Light",
            prefersDark: true
        )

        #expect(model.themeInUse == "Iceberg Light")

        model.select("Front End Delight")

        #expect(model.selection == CmuxTerminalThemePair(light: "Front End Delight", dark: "Front End Delight"))
        #expect(model.themeInUse == "Front End Delight")
    }

    @Test("Changing the app appearance moves the highlight to the side now shown")
    func appearanceChangeFollowsThemeInUse() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, _, _) = try makeModel(
            existingConfig: nil,
            currentThemeValue: "light:Violet Light,dark:3024 Night",
            prefersDark: false
        )
        #expect(model.themeInUse == "Violet Light")

        model.appearanceDidChange(prefersDark: true)

        #expect(model.slotInUse == .dark)
        #expect(model.themeInUse == "3024 Night")
    }

    @Test("A later gallery shows cached themes, then picks up theme files added since")
    func reloadPicksUpAddedThemes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let themesDirectory = root.appendingPathComponent("themes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        try "background = #000000\n".write(to: themesDirectory.appendingPathComponent("Alpha"), atomically: true, encoding: .utf8)

        let (first, _, _) = try makeModel(existingConfig: nil, currentThemeValue: nil, themeDirectories: [themesDirectory])
        await first.load()
        #expect(first.themes.map(\.name) == ["Alpha"])

        try "background = #ffffff\n".write(to: themesDirectory.appendingPathComponent("Beta"), atomically: true, encoding: .utf8)
        let (second, _, _) = try makeModel(existingConfig: nil, currentThemeValue: nil, themeDirectories: [themesDirectory])
        await second.load()

        #expect(second.themes.map(\.name) == ["Alpha", "Beta"])
    }

    @Test("With no theme set, a pick fills both sides so Ghostty accepts it")
    func pickFromDefaultFillsBothSides() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, file, _) = try makeModel(existingConfig: nil, currentThemeValue: nil)

        model.select("GitHub Light Default")

        #expect(model.selection == CmuxTerminalThemePair(light: "GitHub Light Default", dark: "GitHub Light Default"))
        #expect(try file.readContents()?.contains("theme = light:GitHub Light Default,dark:GitHub Light Default") == true)
    }

    @Test("Picking the theme already in effect writes nothing")
    func pickingCurrentThemeIsNoOp() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, file, log) = try makeModel(existingConfig: nil, currentThemeValue: "Nord")

        model.select("Nord")

        #expect(try file.readContents() == nil)
        #expect(log.phases.isEmpty)
        #expect(!model.hasPendingChange)
    }

    @Test("Revert restores the theme from before the first of several picks")
    func revertRestoresSnapshot() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "font-size = 13\n\n# cmux themes start\ntheme = Nord\n# cmux themes end\n"
        let (model, file, log) = try makeModel(existingConfig: original, currentThemeValue: "Nord")

        model.select("Rose Pine Dawn")
        model.select("Rose Pine")
        model.revert()

        #expect(try file.readContents() == original)
        #expect(model.selection == CmuxTerminalThemePair(light: "Nord", dark: "Nord"))
        #expect(!model.hasPendingChange)
        #expect(log.phases == [.preview, .preview, .final])
    }

    @Test("Revert only touches the theme block, keeping edits made since the pick")
    func revertKeepsLaterEdits() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, file, _) = try makeModel(existingConfig: "font-size = 13\n", currentThemeValue: nil)

        model.select("Nord")
        try (try file.readContents()! + "cursor-style = bar\n").write(to: file.url, atomically: true, encoding: .utf8)
        model.revert()

        #expect(try file.readContents() == "font-size = 13\n\ncursor-style = bar\n")
    }

    @Test("Revert restores a pair cmux themes wrote after Settings opened")
    func pickReadsCurrentBlock() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, file, _) = try makeModel(
            existingConfig: nil,
            currentThemeValue: "light:Catppuccin Latte,dark:Catppuccin Mocha"
        )

        // `cmux themes set --dark Dracula` from a terminal while Settings is open.
        try file.write(rawThemeValue: "light:Catppuccin Latte,dark:Dracula")
        model.select("Nord Light")
        #expect(try file.managedThemeValue() == "light:Nord Light,dark:Nord Light")

        model.revert()
        #expect(try file.managedThemeValue() == "light:Catppuccin Latte,dark:Dracula")
    }

    @Test("Revert removes a config file the gallery created")
    func revertRemovesCreatedFile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, file, _) = try makeModel(existingConfig: nil, currentThemeValue: nil)

        model.select("Nord")
        model.revert()

        #expect(try file.readContents() == nil)
    }

    @Test("An empty query lists every theme, those matching the appearance in use first")
    func emptyQueryListsEveryTheme() {
        let themes = [
            theme("3024 Night", background: "#090300"),
            theme("Alabaster", background: "#f7f7f7"),
            theme("Dracula", background: "#282a36"),
            theme("Nord", background: "#2e3440"),
            theme("Nord Light", background: "#e5e9f0"),
        ]

        let light = TerminalThemeGalleryModel.results(in: themes, query: "", slot: .light)
        #expect(light.matchingSlot.map(\.name) == ["Alabaster", "Nord Light"])
        #expect(light.otherAppearance.map(\.name) == ["3024 Night", "Dracula", "Nord"])

        let dark = TerminalThemeGalleryModel.results(in: themes, query: " ", slot: .dark)
        #expect(dark.matchingSlot.map(\.name) == ["3024 Night", "Dracula", "Nord"])
        #expect(dark.otherAppearance.map(\.name) == ["Alabaster", "Nord Light"])
        #expect(dark.themes.count == themes.count)
    }

    @Test("A query returns every matching theme without a cap")
    func searchReturnsEveryMatch() {
        let themes = (0..<600).map { theme("Theme \($0)", background: "#000000") } + [theme("Dracula", background: "#282a36")]

        let dracula = TerminalThemeGalleryModel.results(in: themes, query: "drac", slot: .light)
        #expect(dracula.themes.map(\.name) == ["Dracula"])

        let many = TerminalThemeGalleryModel.results(in: themes, query: "theme", slot: .light)
        #expect(many.themes.count == 600)
    }

    private func theme(_ name: String, background: String) -> TerminalThemeGalleryModel.Theme {
        TerminalThemeGalleryModel.Theme(
            name: name,
            colors: GhosttyThemeColors(parsing: "background = \(background)")
        )
    }
}
