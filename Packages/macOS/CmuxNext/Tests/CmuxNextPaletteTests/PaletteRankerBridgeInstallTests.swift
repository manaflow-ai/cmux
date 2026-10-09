import Foundation
@testable import CmuxNextPalette
import Testing

/// The bridge sends an index's entries to JavaScriptCore once per version: a keystroke on the same
/// index sends only the query (the encode and parse of 2,000 entries were most of a keystroke's
/// 19 ms). Results are the same as sending the entries every time.
@Suite(.paletteRanker) struct PaletteRankerBridgeInstallTests {
    @Test func entriesAreInstalledOncePerVersionWithTheSameResults() throws {
        let index = PaletteSearchIndex(items: PaletteBenchmarkTests.makeItems(count: 300))
        let other = PaletteSearchIndex(items: Array(PaletteBenchmarkTests.makeItems(count: 300).reversed()))
        let now = Date()
        let cached = try PaletteRankerBridge()
        let fresh = try PaletteRankerBridge()
        func rank(_ bridge: PaletteRankerBridge, _ index: PaletteSearchIndex, version: Int?, _ query: String) throws -> [PaletteRankedSection] {
            try bridge.rank(index: index, version: version, query: query, sectionOrders: [], frecency: FrecencyStore(), now: now, showsRecent: false)
        }
        for query in ["sp", "spl", "split", "tab", "new"] {
            #expect(try rank(cached, index, version: 1, query) == rank(fresh, index, version: nil, query), "\(query)")
        }
        #expect(cached.entryInstalls == 1, "one install for five keystrokes on one index")
        // A new version installs again and ranks the new entries.
        #expect(try rank(cached, other, version: 2, "split") == rank(fresh, other, version: nil, "split"))
        #expect(cached.entryInstalls == 2)
    }
}
