import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// The user's aliases and pins (cmux.json `palette.aliases`, `palette.pins`, cx-9ce.43): pinned
/// commands lead the empty palette under Pinned, in the user's order; typing a whole alias puts
/// its command first; a changed setting shows on the next open.
@MainActor
struct PaletteUserRankingTests {
    @MainActor private final class Settings {
        var value = PaletteRankSettings()
    }

    /// The first section once the empty query's rank lands with `id` first.
    private static func waitForFirstSection(_ palette: PaletteController, _ id: String) async {
        for _ in 0..<200 where palette.model.sections.first?.section.id != id {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await palette.model.settle()
    }

    private static func actions(_ section: PaletteResultSection?) -> [String] {
        (section?.rows ?? []).compactMap { $0.item.actionID?.rawValue }
    }

    @Test func pinsLeadTheEmptyPaletteAndAnAliasPutsItsCommandFirst() async throws {
        _ = NSApplication.shared
        let settings = Settings()
        settings.value = PaletteRankSettings(aliases: ["splitRight": ["vs"]], pins: ["closeTab", "splitDown"])
        var sources = PaletteSources()
        sources.rankSettings = { settings.value }
        let palette = PaletteController(registry: .standard(), sources: sources, frecencyPersistence: nil)
        defer { palette.hide() }

        palette.show(.commands)
        await Self.waitForFirstSection(palette, "pinned")
        let pinned = palette.model.sections.first
        #expect(pinned?.section.id == "pinned")
        #expect(pinned?.section.title == "Pinned")
        #expect(Self.actions(pinned) == ["closeTab", "splitDown"])

        palette.model.send(.setQuery("vs"))
        await palette.model.settle()
        #expect(palette.model.rows.first?.item.actionID == "splitRight")

        // The next open reads the setting again.
        palette.hide()
        settings.value.pins = ["newWindow"]
        palette.show(.commands)
        await Self.waitForFirstSection(palette, "pinned")
        #expect(Self.actions(palette.model.sections.first) == ["newWindow"])
    }
}
