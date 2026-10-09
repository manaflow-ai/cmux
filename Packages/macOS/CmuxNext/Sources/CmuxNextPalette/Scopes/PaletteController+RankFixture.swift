public import Foundation

/// One search entry of a scope with its row id, exactly as the shared ranker receives it.
nonisolated struct PaletteRankFixtureEntry: Encodable {
    let id: String
    let entry: PaletteRankerBridgeEntry
}

nonisolated struct PaletteRankFixtureSection: Encodable {
    let id: String
    let title: String
    let order: Int
}

/// The ranker's whole input for one scope: the eval fixture of
/// plans/cmux-next/palette-ranking.md (`webviews/test/fixtures/palette-eval`).
nonisolated struct PaletteRankFixture: Encodable {
    let scope: String
    let showsRecent: Bool
    let sectionOrders: [Int]
    let sections: [PaletteRankFixtureSection]
    let entries: [PaletteRankFixtureEntry]
}

extension PaletteController {
    /// `scope`'s rows as the ranker sees them (title, keywords, subtitle,
    /// section, bias, enabled), JSON. Headless and read-only; nil when the
    /// scope has no page. The ranking eval replays real entries from it.
    public func rankFixture(scope: PaletteScopeID) async -> Data? {
        guard let (page, state) = await loadedPage(scope) else { return nil }
        let fixture = PaletteRankFixture(
            scope: scope.rawValue,
            showsRecent: page.showsRecent,
            sectionOrders: state.sectionOrders,
            sections: state.sections.map { PaletteRankFixtureSection(id: $0.id, title: $0.title, order: $0.order) },
            entries: zip(state.items, state.entries).map { PaletteRankFixtureEntry(id: $0.id, entry: PaletteRankerBridgeEntry($1)) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(fixture)
    }
}
