import Testing

@testable import CmuxCommandPalette

struct CommandPaletteEmojiTitleSearchTests {
    @Test func searchPrefersEmojiPrefixedFullTitleWordsOverPartialTitlePrefix() {
        let entries = [
            FixtureEntry(
                id: "workspace.fullTitleMatch",
                rank: 20,
                title: "🧪 Command Palette",
                searchableTexts: ["🧪 Command Palette", "Workspace", "workspace", "switch", "go"]
            ),
            FixtureEntry(
                id: "workspace.partialTitlePrefix",
                rank: 0,
                title: "Command Palette Archive",
                searchableTexts: ["Command Palette Archive", "Workspace", "workspace", "switch", "go"]
            ),
        ]

        let results = optimizedResults(entries: entries, query: "command palette", resultLimit: 5)

        #expect(results.first?.id == "workspace.fullTitleMatch")
    }

    @Test func searchPrefersEmojiPrefixedTitleWordPrefixOverHiddenTokenMatches() {
        let entries = [
            FixtureEntry(
                id: "workspace.titlePrefixMatch",
                rank: 20,
                title: "🧪 Command Palette Archive",
                searchableTexts: ["🧪 Command Palette Archive", "Workspace", "workspace", "switch", "go"]
            ),
            FixtureEntry(
                id: "workspace.hiddenTokenMatches",
                rank: 0,
                title: "Other Workspace",
                searchableTexts: [
                    "Other Workspace",
                    "Workspace",
                    "workspace",
                    "switch",
                    "go",
                    "command",
                    "palette",
                ]
            ),
        ]

        let results = optimizedResults(entries: entries, query: "command palette", resultLimit: 5)

        #expect(results.first?.id == "workspace.titlePrefixMatch")
    }

    @Test func searchPrefersEmojiPrefixedFullTitleWordsWithRepeatedQuerySpaces() {
        let entries = [
            FixtureEntry(
                id: "workspace.fullTitleMatch",
                rank: 20,
                title: "🧪 Command Palette",
                searchableTexts: ["🧪 Command Palette", "Workspace", "workspace", "switch", "go"]
            ),
            FixtureEntry(
                id: "workspace.hiddenTokenMatches",
                rank: 0,
                title: "Other Workspace",
                searchableTexts: ["Other Workspace", "Workspace", "command", "palette"]
            ),
        ]

        let results = optimizedResults(entries: entries, query: "command  palette", resultLimit: 5)

        #expect(results.first?.id == "workspace.fullTitleMatch")
    }

    @Test func nucleoFFIPrefersEmojiPrefixedFullTitleWordsOverPartialTitlePrefix() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = [
            FixtureEntry(
                id: "workspace.fullTitleMatch",
                rank: 20,
                title: "🧪 Command Palette",
                searchableTexts: ["🧪 Command Palette", "Workspace", "workspace", "switch", "go"]
            ),
            FixtureEntry(
                id: "workspace.partialTitlePrefix",
                rank: 0,
                title: "Command Palette Archive",
                searchableTexts: ["Command Palette Archive", "Workspace", "workspace", "switch", "go"]
            ),
        ]
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "command palette", limit: 5).map(\.id)

        #expect(resultIDs.first == "workspace.fullTitleMatch")
    }

    @Test func nucleoFFIPrefersEmojiPrefixedTitleWordPrefixOverHiddenTokenMatches() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = [
            FixtureEntry(
                id: "workspace.titlePrefixMatch",
                rank: 20,
                title: "🧪 Command Palette Archive",
                searchableTexts: ["🧪 Command Palette Archive", "Workspace", "workspace", "switch", "go"]
            ),
            FixtureEntry(
                id: "workspace.hiddenTokenMatches",
                rank: 0,
                title: "Other Workspace",
                searchableTexts: [
                    "Other Workspace",
                    "Workspace",
                    "workspace",
                    "switch",
                    "go",
                    "command",
                    "palette",
                ]
            ),
        ]
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "command palette", limit: 5).map(\.id)

        #expect(resultIDs.first == "workspace.titlePrefixMatch")
    }

    @Test func nucleoFFIPrefersEmojiPrefixedFullTitleWordsWithRepeatedQuerySpaces() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = [
            FixtureEntry(
                id: "workspace.fullTitleMatch",
                rank: 20,
                title: "🧪 Command Palette",
                searchableTexts: ["🧪 Command Palette", "Workspace", "workspace", "switch", "go"]
            ),
            FixtureEntry(
                id: "workspace.hiddenTokenMatches",
                rank: 0,
                title: "Other Workspace",
                searchableTexts: ["Other Workspace", "Workspace", "command", "palette"]
            ),
        ]
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "command  palette", limit: 5).map(\.id)

        #expect(resultIDs.first == "workspace.fullTitleMatch")
    }
}
