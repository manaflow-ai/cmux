public import Foundation

/// Sendable command metadata captured on the main actor before expensive
/// search normalization moves to the command-palette preparation actor.
public struct CommandPaletteSearchCorpusDescriptor: Sendable, Equatable {
    public let id: String
    public let rank: Int
    public let title: String
    public let searchableTexts: [String]

    public init(id: String, rank: Int, title: String, searchableTexts: [String]) {
        self.id = id
        self.rank = rank
        self.title = title
        self.searchableTexts = searchableTexts
    }
}

/// Immutable, fully searchable command catalog prepared away from the main
/// actor. Default matches let the first palette frame render complete rows.
public struct CommandPalettePreparedSearchCorpus: Sendable {
    public let fingerprint: Int
    public let entries: [CommandPaletteSearchCorpusEntry<String>]
    public let entriesByID: [String: CommandPaletteSearchCorpusEntry<String>]
    public let searchIndex: CommandPaletteNucleoSearchIndex<String>?
    public let defaultMatches: [CommandPaletteResolvedSearchMatch]
}

/// Serializes and caches command-catalog preparation on a non-main actor.
/// Command actions remain main-actor-owned; only immutable search metadata
/// crosses this boundary.
public actor CommandPaletteSearchCorpusPreloader {
    private var cachedFingerprint: Int?
    private var cachedDescriptors: [CommandPaletteSearchCorpusDescriptor] = []
    private var cachedEntries: [CommandPaletteSearchCorpusEntry<String>] = []
    private var cachedEntriesByID: [String: CommandPaletteSearchCorpusEntry<String>] = [:]
    private var cachedSearchIndex: CommandPaletteNucleoSearchIndex<String>?

    public init() {}

    public func prepare(
        descriptors: [CommandPaletteSearchCorpusDescriptor],
        fingerprint: Int,
        usageHistory: [String: CommandPaletteUsageEntry],
        historyTimestamp: TimeInterval
    ) -> CommandPalettePreparedSearchCorpus {
        if cachedFingerprint != fingerprint || cachedDescriptors != descriptors {
            let entries = descriptors.map { descriptor in
                CommandPaletteSearchCorpusEntry(
                    payload: descriptor.id,
                    rank: descriptor.rank,
                    title: descriptor.title,
                    searchableTexts: descriptor.searchableTexts
                )
            }
            cachedFingerprint = fingerprint
            cachedDescriptors = descriptors
            cachedEntries = entries
            cachedEntriesByID = CommandPaletteSearchOrchestrator.firstValueDictionary(
                entries,
                keyedBy: \.payload
            )
            cachedSearchIndex = CommandPaletteNucleoSearchIndex(entries: entries)
        }

        let defaultMatches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
            searchIndex: cachedSearchIndex,
            searchCorpus: cachedEntries,
            searchCorpusByID: cachedEntriesByID,
            query: "",
            usageHistory: usageHistory,
            queryIsEmpty: true,
            historyTimestamp: historyTimestamp
        )
        return CommandPalettePreparedSearchCorpus(
            fingerprint: fingerprint,
            entries: cachedEntries,
            entriesByID: cachedEntriesByID,
            searchIndex: cachedSearchIndex,
            defaultMatches: defaultMatches
        )
    }
}
