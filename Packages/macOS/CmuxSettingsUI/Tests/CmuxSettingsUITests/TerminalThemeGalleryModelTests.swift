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
        prefersDark: Bool = false
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
                themeDirectories: [],
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
        #expect(model.slot == .dark)

        model.select("Nord")

        #expect(model.selection == CmuxTerminalThemePair(light: "Catppuccin Latte", dark: "Nord"))
        #expect(try file.readContents() == """
        font-size = 13

        # cmux themes start
        theme = light:Catppuccin Latte,dark:Nord
        # cmux themes end

        """)
        #expect(log.phases == [.preview])
        #expect(model.hasPendingChange)
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
        model.slot = .dark
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

    @Test("A pick keeps the other side as cmux themes changed it after Settings opened")
    func pickReadsCurrentBlock() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, file, _) = try makeModel(
            existingConfig: nil,
            currentThemeValue: "light:Catppuccin Latte,dark:Catppuccin Mocha"
        )

        // `cmux themes set --dark Dracula` from a terminal while Settings is open.
        try file.write(rawThemeValue: "light:Catppuccin Latte,dark:Dracula")
        model.select("Nord Light")

        #expect(try file.managedThemeValue() == "light:Nord Light,dark:Dracula")
        #expect(model.selection == CmuxTerminalThemePair(light: "Nord Light", dark: "Dracula"))
    }

    @Test("Revert removes a config file the gallery created")
    func revertRemovesCreatedFile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, file, _) = try makeModel(existingConfig: nil, currentThemeValue: nil)

        model.select("Nord")
        model.revert()

        #expect(try file.readContents() == nil)
    }

    @Test("An empty query shows curated themes that exist, matching the slot first")
    func curatedResultsFollowSlot() {
        let themes = [
            theme("Nord", background: "#2e3440"),
            theme("Nord Light", background: "#e5e9f0"),
            theme("Dracula", background: "#282a36"),
            theme("catppuccin latte", background: "#eff1f5"),
        ]

        let light = TerminalThemeGalleryModel.results(in: themes, query: "", slot: .light)
        #expect(light.themes.map(\.name) == ["catppuccin latte", "Nord Light", "Nord"])
        let dark = TerminalThemeGalleryModel.results(in: themes, query: " ", slot: .dark)
        #expect(dark.themes.map(\.name) == ["Nord", "catppuccin latte", "Nord Light"])
    }

    @Test("A query searches every theme and caps the card count")
    func searchCapsResults() {
        let themes = (0..<60).map { theme("Theme \($0)", background: "#000000") } + [theme("Dracula", background: "#282a36")]

        let dracula = TerminalThemeGalleryModel.results(in: themes, query: "drac", slot: .light)
        #expect(dracula.themes.map(\.name) == ["Dracula"])
        #expect(!dracula.isTruncated)

        let many = TerminalThemeGalleryModel.results(in: themes, query: "theme", slot: .light)
        #expect(many.themes.count == TerminalThemeGalleryModel.searchResultLimit)
        #expect(many.isTruncated)
    }

    private func theme(_ name: String, background: String) -> TerminalThemeGalleryModel.Theme {
        TerminalThemeGalleryModel.Theme(
            name: name,
            colors: GhosttyThemeColors(parsing: "background = \(background)")
        )
    }
}
