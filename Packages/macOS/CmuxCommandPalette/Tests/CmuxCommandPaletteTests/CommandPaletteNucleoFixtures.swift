import Darwin
import Foundation

@testable import CmuxCommandPalette

struct FixtureEntry {
    let id: String
    let rank: Int
    let title: String
    let searchableTexts: [String]
}

struct FixtureResult: Equatable {
    let id: String
    let rank: Int
    let title: String
    let score: Int
}

struct NucleoResult: Equatable {
    let id: String
    let rank: Int
    let title: String
    let score: Double
}

func makeOpenFolderEntries() -> [FixtureEntry] {
    [
        FixtureEntry(
            id: "palette.newWorkspace",
            rank: 0,
            title: "New Workspace",
            searchableTexts: ["New Workspace", "Workspace", "create", "new", "workspace"]
        ),
        FixtureEntry(
            id: "palette.newWindow",
            rank: 1,
            title: "New Window",
            searchableTexts: ["New Window", "Window", "create", "new", "window"]
        ),
        FixtureEntry(
            id: "palette.openFolder",
            rank: 2,
            title: "Open Folder...",
            searchableTexts: ["Open Folder...", "Workspace", "open", "folder", "repository", "project", "directory"]
        ),
        FixtureEntry(
            id: "palette.openFolderInVSCodeInline",
            rank: 3,
            title: "Open Folder in VS Code (Inline)...",
            searchableTexts: [
                "Open Folder in VS Code (Inline)...",
                "VS Code Inline",
                "open",
                "folder",
                "directory",
                "project",
                "vs",
                "code",
                "inline",
                "editor",
                "browser",
            ]
        ),
    ]
}

func makeInitialismWorkspaceEntries() -> [FixtureEntry] {
    [
        FixtureEntry(
            id: "workspace.yarrowImageSorter",
            rank: 0,
            title: "Yarrow Image Sorter",
            searchableTexts: ["Yarrow Image Sorter", "Workspace", "workspace", "switch", "go"]
        ),
        FixtureEntry(
            id: "workspace.indigoMarkdownStudio",
            rank: 1,
            title: "Indigo Markdown Studio",
            searchableTexts: ["Indigo Markdown Studio", "Workspace", "workspace", "switch", "go"]
        ),
        FixtureEntry(
            id: "workspace.ivoryMeetingNotes",
            rank: 2,
            title: "Ivory Meeting Notes",
            searchableTexts: ["Ivory Meeting Notes", "Workspace", "workspace", "switch", "go"]
        ),
        FixtureEntry(
            id: "workspace.graniteMusicVault",
            rank: 3,
            title: "Granite Music Vault",
            searchableTexts: ["Granite Music Vault", "Workspace", "workspace", "switch", "go"]
        ),
        FixtureEntry(
            id: "workspace.nimbusInvoiceDesk",
            rank: 4,
            title: "Nimbus Invoice Desk",
            searchableTexts: ["Nimbus Invoice Desk", "Workspace", "workspace", "switch", "go"]
        ),
    ]
}

func makeEdgeCasePaletteEntries(generatedWorkspaceCount: Int) -> [FixtureEntry] {
    var entries = makeOpenFolderEntries()
    entries.append(
        FixtureEntry(
            id: "palette.markWorkspaceUnread",
            rank: entries.count,
            title: "Mark Workspace as Unread",
            searchableTexts: [
                "Mark Workspace as Unread",
                "Workspace",
                "mark",
                "unread",
                "notification",
            ]
        )
    )
    entries.append(contentsOf: makeInitialismWorkspaceEntries().map { entry in
        FixtureEntry(
            id: entry.id,
            rank: entries.count + entry.rank,
            title: entry.title,
            searchableTexts: entry.searchableTexts
        )
    })
    entries.append(
        FixtureEntry(
            id: "workspace.cafeUnicodeNotes",
            rank: entries.count,
            title: "Café Unicode Notes",
            searchableTexts: [
                "Café Unicode Notes",
                "Cafe Unicode Notes",
                "cafe",
                "unicode",
                "workspace",
            ]
        )
    )

    let generatedRankOffset = entries.count
    entries.append(contentsOf: makeLargeWorkspaceSwitcherEntries(count: generatedWorkspaceCount).map { entry in
        FixtureEntry(
            id: entry.id,
            rank: generatedRankOffset + entry.rank,
            title: entry.title,
            searchableTexts: entry.searchableTexts
        )
    })
    return entries
}

func makeLargeWorkspaceSwitcherEntries(count: Int) -> [FixtureEntry] {
    (0..<count).map { index in
        let projectSlug = "project-\(index)-cmd-p-search-performance"
        let worktreeSlug = "feature-\(index)-palette-latency"
        let title = "Workspace \(index) \(projectSlug)"
        let keywords = CommandPaletteSwitcherSearchIndexer(
            baseKeywords: [
                "workspace",
                "switch",
                "go",
                "open",
                title,
                "Window \((index % 4) + 1)",
            ],
            metadata: CommandPaletteSwitcherSearchMetadata(
                directories: [
                    "/Users/example/dev/cmuxterm-hq/worktrees/\(worktreeSlug)",
                    "/Users/example/dev/cmuxterm-hq/worktrees/\(worktreeSlug)/repo",
                ],
                branches: [
                    "feature/palette-latency-\(index)",
                    "task/cmd-p-search-\(index % 17)",
                ],
                ports: [
                    3000 + (index % 50),
                    4200 + (index % 25),
                    9200 + (index % 10),
                ],
                description: "Palette performance fixture \(index) for \(projectSlug)"
            ),
            detail: .workspace
        ).keywords
        return FixtureEntry(
            id: "workspace.large.\(index)",
            rank: index,
            title: title,
            searchableTexts: [title, "Workspace"] + keywords
        )
    }
}

func searchCorpus(entries: [FixtureEntry]) -> [CommandPaletteSearchCorpusEntry<String>] {
    entries.map { entry in
        CommandPaletteSearchCorpusEntry(
            payload: entry.id,
            rank: entry.rank,
            title: entry.title,
            searchableTexts: entry.searchableTexts
        )
    }
}

func optimizedResults(
    corpus: [CommandPaletteSearchCorpusEntry<String>],
    query: String,
    resultLimit: Int
) -> [FixtureResult] {
    CommandPaletteSearchEngine(entries: corpus).search(
            query: query,
        resultLimit: resultLimit
    ) { _, _ in 0 }
        .map {
            FixtureResult(
                id: $0.payload,
                rank: $0.rank,
                title: $0.title,
                score: $0.score
            )
        }
}

func optimizedResults(
    entries: [FixtureEntry],
    query: String,
    resultLimit: Int
) -> [FixtureResult] {
    optimizedResults(corpus: searchCorpus(entries: entries), query: query, resultLimit: resultLimit)
}

func correctnessComparison(
    corpus: [CommandPaletteSearchCorpusEntry<String>],
    queries: [String],
    index: NucleoIndex,
    resultLimit: Int
) throws -> (
    queryCount: Int,
    top1Agreement: Int,
    meanTop10Overlap: Double,
    top1Mismatches: [String]
) {
    var top1Agreement = 0
    var totalTop10Overlap = 0.0
    var top1Mismatches: [String] = []

    for query in queries {
        let swiftIDs = optimizedResults(corpus: corpus, query: query, resultLimit: resultLimit)
            .map(\.id)
        let nucleoIDs = try index.search(query: query, limit: resultLimit).map(\.id)
        if swiftIDs.first == nucleoIDs.first {
            top1Agreement += 1
        } else {
            let swiftTop = swiftIDs.first ?? "<none>"
            let nucleoTop = nucleoIDs.first ?? "<none>"
            top1Mismatches.append("\(query): swift=\(swiftTop) nucleo=\(nucleoTop)")
        }

        let swiftTop10 = Set(swiftIDs.prefix(10))
        let nucleoTop10 = Set(nucleoIDs.prefix(10))
        if !swiftTop10.isEmpty || !nucleoTop10.isEmpty {
            totalTop10Overlap += Double(swiftTop10.intersection(nucleoTop10).count) / 10.0
        }
    }

    return (
        queryCount: queries.count,
        top1Agreement: top1Agreement,
        meanTop10Overlap: queries.isEmpty ? 0 : totalTop10Overlap / Double(queries.count),
        top1Mismatches: top1Mismatches
    )
}

func fastTypingPrefixes(_ text: String) -> [String] {
    text.indices.map { index in
        String(text[...index])
    }
}

func edgeCaseTypingQueries() -> [String] {
    var queries: [String] = []
    for text in [
        "ims",
        "wunr",
        "open folder",
        "workspace 1901",
        "feature/palette-latency-177",
        "project-1999",
        "cmd-p-search",
        "cafe unicode",
        "zzzzzzzz",
    ] {
        queries.append(contentsOf: fastTypingPrefixes(text))
    }
    queries.append(contentsOf: [
        "",
        "   ",
        "  OPEN   FOLDER  ",
        "Window 3",
        "3007",
        "4207",
        "9207",
        "task/cmd-p-search-7",
        "feature palette latency",
        "project 42 cmd p",
        "workspace/branch:177",
        "café",
        "Cafe",
        "no-match-query",
    ])
    return queries
}

func estimatedDroppedFrames(
    for queryDurationsMs: [Double],
    frameBudgetMs: Double = 1000.0 / 60.0
) -> Int {
    queryDurationsMs.reduce(0) { total, durationMs in
        total + max(0, Int(ceil(durationMs / frameBudgetMs)) - 1)
    }
}

func benchmarkElapsedMs(operation: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    operation()
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    return Double(elapsed) / 1_000_000
}

func percentile(_ values: [Double], percentile: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let clampedPercentile = min(1, max(0, percentile))
    let index = Int((Double(sorted.count - 1) * clampedPercentile).rounded())
    return sorted[index]
}

func repeatedQueries(_ baseQueries: [String], repetitions: Int) -> [String] {
    Array(repeating: baseQueries, count: repetitions).flatMap { $0 }
}
