import Foundation
import Testing
@testable import CmuxCommandPalette

@Suite
struct CommandPaletteSearchCorpusPreloaderTests {
    @Test
    func preparesCompleteDefaultResultsAndUsageOrdering() async {
        let preloader = CommandPaletteSearchCorpusPreloader()
        let now = Date().timeIntervalSince1970
        let prepared = await preloader.prepare(
            descriptors: [
                CommandPaletteSearchCorpusDescriptor(
                    id: "alpha",
                    rank: 0,
                    title: "Alpha",
                    searchableTexts: ["Alpha", "first"]
                ),
                CommandPaletteSearchCorpusDescriptor(
                    id: "beta",
                    rank: 1,
                    title: "Beta",
                    searchableTexts: ["Beta", "second"]
                ),
            ],
            fingerprint: 42,
            usageHistory: [
                "beta": CommandPaletteUsageEntry(useCount: 20, lastUsedAt: now),
            ],
            historyTimestamp: now
        )

        #expect(prepared.entries.count == 2)
        #expect(prepared.entriesByID["alpha"]?.searchableTextSet.contains("first") == true)
        #expect(prepared.defaultMatches.map(\.commandID) == ["beta", "alpha"])
    }
}
