import CmuxDesignSystem
import Testing

@Suite
struct WorkspaceTabColorPaletteTests {
    @Test
    func builtInPaletteKeepsOriginalOrderAndValues() {
        let palette = WorkspaceTabColorPalette.workspaceTabs

        #expect(palette.builtInEntries.map(\.name) == [
            "Red",
            "Crimson",
            "Orange",
            "Amber",
            "Olive",
            "Green",
            "Teal",
            "Aqua",
            "Blue",
            "Navy",
            "Indigo",
            "Purple",
            "Magenta",
            "Rose",
            "Brown",
            "Charcoal",
        ])
        #expect(palette.defaultColorHex(named: "Indigo") == "#283593")
    }

    @Test
    func defaultPaletteMapToleratesDuplicateBuiltInNames() {
        let palette = WorkspaceTabColorPalette(
            builtInEntries: [
                WorkspaceTabColorEntry(name: "Blue", hex: "#111111"),
                WorkspaceTabColorEntry(name: "Blue", hex: "#222222"),
            ]
        )

        #expect(palette.defaultPaletteMap == ["Blue": "#222222"])
        #expect(palette.effectivePaletteMap(stored: nil) == ["Blue": "#222222"])
    }

    @Test
    func appliesOverridesAndSortsCustomEntriesAfterBuiltIns() {
        let palette = WorkspaceTabColorPalette.workspaceTabs
        let entries = palette.entries(stored: [
            "Indigo": "#111111",
            "Neon Mint": "#00F5D4",
            "Blue": "#222222",
        ])

        #expect(entries.map(\.name) == ["Blue", "Indigo", "Neon Mint"])
        #expect(entries.map(\.hex) == ["#222222", "#111111", "#00F5D4"])
    }

    @Test
    func resolvesHexAndPaletteNames() {
        let palette = WorkspaceTabColorPalette.workspaceTabs

        #expect(palette.resolvedColorHex("#abc123", stored: nil) == "#ABC123")
        #expect(palette.resolvedColorHex("indigo", stored: nil) == "#283593")
        #expect(palette.resolvedColorHex("Neon Mint", stored: ["Neon Mint": "#00F5D4"]) == "#00F5D4")
        #expect(palette.resolvedColorHex("unknown", stored: nil) == nil)
    }

    @Test
    func cacheFingerprintIsSorted() {
        let palette = WorkspaceTabColorPalette.workspaceTabs

        #expect(palette.cacheFingerprint(stored: [
            "Zulu": "#111111",
            "Alpha": "#222222",
        ]) == "Alpha=#222222\nZulu=#111111")
    }

    @Test
    func addsCustomColorsWithStableNamesAndDeduplicatesHexValues() throws {
        let palette = WorkspaceTabColorPalette.workspaceTabs

        let first = try #require(palette.paletteMapByAddingCustomColor("#00aa33", stored: nil))
        #expect(first.normalizedHex == "#00AA33")
        #expect(first.paletteMap["Custom 1"] == "#00AA33")

        let second = try #require(palette.paletteMapByAddingCustomColor("#00AA33", stored: first.paletteMap))
        #expect(second.normalizedHex == "#00AA33")
        #expect(second.paletteMap == first.paletteMap)
    }

    @Test
    func nextCustomColorNameSkipsExistingNamesCaseInsensitively() {
        let palette = WorkspaceTabColorPalette.workspaceTabs

        #expect(
            palette.nextCustomColorName(
                existingNames: ["Custom 1", "custom 2", "Other"],
                startingAt: 0
            ) == "Custom 3"
        )
    }
}
