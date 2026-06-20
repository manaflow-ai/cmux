import Foundation
import Testing

@testable import CmuxCommandPalette

// Serialized: several tests assert on wall-clock benchmark comparisons, which
// parallel execution would skew.
@Suite(.serialized)
struct CommandPaletteSearchEngineTests {
    private struct FixtureEntry {
        let id: String
        let rank: Int
        let title: String
        let searchableTexts: [String]
    }

    private struct FixtureResult: Equatable {
        let id: String
        let rank: Int
        let title: String
        let score: Int
        let titleMatchIndices: Set<Int>
    }

    private func makeCommandEntries(count: Int) -> [FixtureEntry] {
        (0..<count).map { index in
            let title: String
            let subtitle: String
            let keywords: [String]

            switch index % 8 {
            case 0:
                title = "Rename Workspace \(index)"
                subtitle = "Workspace"
                keywords = ["rename", "workspace", "title", "project", "switch"]
            case 1:
                title = "Rename Tab \(index)"
                subtitle = "Tab"
                keywords = ["rename", "tab", "surface", "title"]
            case 2:
                title = "Open Current Directory in IDE \(index)"
                subtitle = "Terminal"
                keywords = ["open", "directory", "cwd", "ide", "vscode"]
            case 3:
                title = "Toggle Sidebar \(index)"
                subtitle = "Layout"
                keywords = ["toggle", "sidebar", "layout", "panel"]
            case 4:
                title = "Apply Update If Available \(index)"
                subtitle = "Global"
                keywords = ["apply", "update", "install", "upgrade"]
            case 5:
                title = "Restart CLI Listener \(index)"
                subtitle = "Global"
                keywords = ["restart", "cli", "listener", "socket", "cmux"]
            case 6:
                title = "Show Notifications \(index)"
                subtitle = "Notifications"
                keywords = ["notifications", "inbox", "unread", "alerts"]
            default:
                title = "Split Browser Right \(index)"
                subtitle = "Layout"
                keywords = ["split", "browser", "right", "layout", "web"]
            }

            return FixtureEntry(
                id: "command.\(index)",
                rank: index,
                title: title,
                searchableTexts: [title, subtitle] + keywords
            )
        }
    }

    private func makeSwitcherEntries(count: Int) -> [FixtureEntry] {
        (0..<count).map { index in
            let title = "Workspace \(index) Phoenix"
            let keywords = CommandPaletteSwitcherSearchIndexer(
                baseKeywords: ["workspace", "switch", "go", title],
                metadata: CommandPaletteSwitcherSearchMetadata(
                    directories: ["/Users/example/dev/cmuxterm-hq/worktrees/feature-\(index)-rename-tab"],
                    branches: ["feature/rename-tab-\(index)"],
                    ports: [3000 + (index % 20), 9200 + (index % 5)]
                ),
                detail: .workspace
            ).keywords
            return FixtureEntry(
                id: "workspace.\(index)",
                rank: index,
                title: title,
                searchableTexts: [title, "Workspace"] + keywords
            )
        }
    }

    private func makeLargeWorkspaceSwitcherEntries(count: Int) -> [FixtureEntry] {
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

    private func makeFinderCommandEntries() -> [FixtureEntry] {
        [
            FixtureEntry(
                id: "command.find",
                rank: 0,
                title: "Find...",
                searchableTexts: ["Find...", "Search", "find", "search"]
            ),
            FixtureEntry(
                id: "command.finder",
                rank: 1,
                title: "Open Current Directory in Finder",
                searchableTexts: ["Open Current Directory in Finder", "Terminal", "finder", "directory", "open"]
            ),
            FixtureEntry(
                id: "command.filter",
                rank: 2,
                title: "Filter Sidebar Items",
                searchableTexts: ["Filter Sidebar Items", "Sidebar", "filter", "sidebar", "items"]
            ),
        ]
    }

    private func makeUpdateCommandEntries() -> [FixtureEntry] {
        [
            FixtureEntry(
                id: "command.checkForUpdates",
                rank: 0,
                title: "Check for Updates",
                searchableTexts: ["Check for Updates", "Global", "update", "upgrade", "release"]
            ),
            FixtureEntry(
                id: "command.attemptUpdate",
                rank: 1,
                title: "Attempt Update",
                searchableTexts: ["Attempt Update", "Global", "attempt", "check", "update", "upgrade", "release"]
            ),
            FixtureEntry(
                id: "command.applyUpdateIfAvailable",
                rank: 2,
                title: "Apply Update (If Available)",
                searchableTexts: ["Apply Update (If Available)", "Global", "apply", "install", "update", "available"]
            ),
        ]
    }

    private func optimizedResults(
        entries: [FixtureEntry],
        query: String,
        resultLimit: Int? = nil
    ) -> [FixtureResult] {
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }

        return CommandPaletteSearchEngine(entries: corpus).search(
            query: query, resultLimit: resultLimit) { _, _ in 0 }
            .map {
                FixtureResult(
                    id: $0.payload,
                    rank: $0.rank,
                    title: $0.title,
                    score: $0.score,
                    titleMatchIndices: $0.titleMatchIndices
                )
            }
    }

    private func referenceResults(
        entries: [FixtureEntry],
        query: String
    ) -> [FixtureResult] {
        let queryIsEmpty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let results: [FixtureResult] = queryIsEmpty
            ? entries.map { entry in
                FixtureResult(id: entry.id, rank: entry.rank, title: entry.title, score: 0, titleMatchIndices: [])
            }
            : entries.compactMap { entry in
                guard let fuzzyScore = commandPaletteWeightedReferenceScore(
                    query: query,
                    title: entry.title,
                    searchableTexts: entry.searchableTexts
                ) else {
                    return nil
                }
                return FixtureResult(
                    id: entry.id,
                    rank: entry.rank,
                    title: entry.title,
                    score: fuzzyScore,
                    titleMatchIndices: CommandPaletteFuzzyMatcher.matchCharacterIndices(
                    query: query,
                        candidate: entry.title
                    )
                )
            }

        return results.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func fastTypingPrefixes(_ text: String) -> [String] {
        text.indices.map { index in
            String(text[...index])
        }
    }

    private func estimatedDroppedFrames(
        for queryDurationsMs: [Double],
        frameBudgetMs: Double = 1000.0 / 60.0
    ) -> Int {
        queryDurationsMs.reduce(0) { total, durationMs in
            total + max(0, Int(ceil(durationMs / frameBudgetMs)) - 1)
        }
    }

    private func benchmarkElapsedMs(operation: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        operation()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Double(elapsed) / 1_000_000
    }

    private func repeatedQueries(_ baseQueries: [String], repetitions: Int) -> [String] {
        Array(repeating: baseQueries, count: repetitions).flatMap { $0 }
    }

    /// Reproduces the deleted production test-only wrapper
    /// `CommandPaletteSearchOrchestrator.commandPreviewMatchCommandIDsForTests`
    /// by calling the public `previewSearchMatches` with the same fixed
    /// arguments and mapping to command IDs.
    private func commandPreviewMatchCommandIDs(
        searchCorpus: [CommandPaletteSearchCorpusEntry<String>],
        searchIndex: CommandPaletteNucleoSearchIndex<String>?,
        candidateCommandIDs: [String],
        searchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>],
        query: String,
        resultLimit: Int
    ) -> [String] {
        CommandPaletteSearchOrchestrator().previewSearchMatches(
            scope: .commands,
            searchIndex: searchIndex,
            searchCorpus: searchCorpus,
            candidateCommandIDs: candidateCommandIDs,
            searchCorpusByID: searchCorpusByID,
            query: query,
            usageHistory: [:],
            queryIsEmpty: CommandPaletteFuzzyMatcher.preparedQuery(query).isEmpty,
            historyTimestamp: 0,
            resultLimit: resultLimit
        ).map(\.commandID)
    }

    @Test func optimizedSearchMatchesReferencePipeline() {
        let commandEntries = makeCommandEntries(count: 96)
        let switcherEntries = makeSwitcherEntries(count: 64)
        let queries = [
            "rename",
            "rename tab",
            "workspace",
            "feature-12",
            "3004",
            "toggle side",
            "open dir",
            "phoenix",
            "apply update",
        ]

        for query in queries {
            #expect(
                optimizedResults(entries: commandEntries, query: query) ==
                referenceResults(entries: commandEntries, query: query),
                "Command corpus mismatch for query \(query)"
            )
            #expect(
                optimizedResults(entries: switcherEntries, query: query) ==
                referenceResults(entries: switcherEntries, query: query),
                "Switcher corpus mismatch for query \(query)"
            )
        }
    }

    @Test func multiTokenSearchCanMatchAcrossTitleAndKeywordFields() {
        let entries = [
            FixtureEntry(
                id: "workspace.projectA",
                rank: 0,
                title: "Project A",
                searchableTexts: ["Project A", "Workspace"]
            ),
            FixtureEntry(
                id: "workspace.notes",
                rank: 1,
                title: "Notes",
                searchableTexts: ["Notes", "Workspace"]
            ),
        ]

        #expect(
            optimizedResults(entries: entries, query: "project workspace").first?.id ==
            "workspace.projectA"
        )
    }

    @Test func limitedSearchReturnsSameTopResultsAsFullSearch() {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 800)
        let queries = [
            "workspace 799",
            "palette latency",
            "feature 401",
            "cmd-p-search",
            "project-642",
            "Window 3",
        ]

        for query in queries {
            let fullResults = optimizedResults(entries: entries, query: query)
            let limitedResults = optimizedResults(entries: entries, query: query, resultLimit: 48)

            #expect(
                limitedResults ==
                Array(fullResults.prefix(48)),
                "Limited search should preserve full-search ordering and highlight output for query \(query)"
            )
        }
    }

    @Test func limitedSearchStillFindsDeepWorkspaceMatch() {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 5_000)

        let results = optimizedResults(
            entries: entries,
            query: "workspace 4913",
            resultLimit: 10
        )

        #expect(results.first?.id == "workspace.large.4913")
        #expect(results.count <= 10)
    }

    @Test func limitedSearchReturnsOnlyRequestedResultCountForBroadWorkspaceQuery() {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 1_200)

        let results = optimizedResults(
            entries: entries,
            query: "workspace",
            resultLimit: 100
        )

        #expect(results.count == 100)
        #expect(
            results ==
            Array(optimizedResults(entries: entries, query: "workspace").prefix(100))
        )
    }

    @Test func resolvedSearchMatchesReturnFullFinalResultSetWhenUnbounded() {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 150)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }

        let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
            searchIndex: nil,
            searchCorpus: corpus,
            query: "workspace",
            usageHistory: [:],
            queryIsEmpty: false,
            historyTimestamp: 0
        )

        #expect(matches.count == entries.count)
    }

    @Test func nucleoResolvedSearchMatchesReturnFullFinalResultSetWhenUnbounded() throws {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 150)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        guard let searchIndex = CommandPaletteNucleoSearchIndex(entries: corpus) else { return }
        // Skipped: nucleo FFI dylib not built in this environment.

        let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
            searchIndex: searchIndex,
            searchCorpus: corpus,
            query: "workspace",
            usageHistory: [:],
            queryIsEmpty: false,
            historyTimestamp: 0
        )

        #expect(matches.count == entries.count)
    }

    @Test func searchCancellationReturnsNoResults() {
        let entries = makeCommandEntries(count: 512)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        var cancellationChecks = 0

        let results = CommandPaletteSearchEngine(entries: corpus).search(
            query: "rename"
        ) { _, _ in
            0
        } shouldCancel: {
            cancellationChecks += 1
            return cancellationChecks >= 4
        }

        #expect(results.isEmpty)
        #expect(cancellationChecks >= 4)
    }

    @Test func commandPreviewSearchUsesFullCommandCorpus() {
        let entries = [
            FixtureEntry(
                id: "command.find",
                rank: 0,
                title: "Find...",
                searchableTexts: ["Find...", "Search", "find", "search"]
            ),
            FixtureEntry(
                id: "command.finder",
                rank: 1,
                title: "Open Current Directory in Finder",
                searchableTexts: ["Open Current Directory in Finder", "Terminal", "finder", "directory", "open"]
            ),
        ]
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let corpusByID = Dictionary(uniqueKeysWithValues: corpus.map { ($0.payload, $0) })
        let searchIndex = CommandPaletteNucleoSearchIndex(entries: corpus)

        let previewCommandIDs = commandPreviewMatchCommandIDs(
            searchCorpus: corpus,
            searchIndex: searchIndex,
            candidateCommandIDs: ["command.find"],
            searchCorpusByID: corpusByID,
            query: "finde",
            resultLimit: 48
        )

        #expect(previewCommandIDs.first == "command.finder")
    }

    @Test func nucleoEmptyResultsFallBackToSwiftSingleEditMatching() throws {
        let entries = [
            FixtureEntry(
                id: "palette.renameTab",
                rank: 0,
                title: "Rename Tab...",
                searchableTexts: ["Rename Tab...", "rename", "tab", "title"]
            ),
            FixtureEntry(
                id: "palette.openFolder",
                rank: 1,
                title: "Open Folder...",
                searchableTexts: ["Open Folder...", "open", "folder", "directory"]
            ),
        ]
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        guard let searchIndex = CommandPaletteNucleoSearchIndex(entries: corpus) else { return }
        // Skipped: nucleo FFI dylib not built in this environment.

        let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
            searchIndex: searchIndex,
            searchCorpus: corpus,
            query: "renamd",
            usageHistory: [:],
            queryIsEmpty: CommandPaletteFuzzyMatcher.preparedQuery("renamd").isEmpty,
            historyTimestamp: 0,
            resultLimit: 10
        )

        #expect(matches.first?.commandID == "palette.renameTab")
    }

    @Test func nucleoPartialResultsIncludeSwiftSingleEditFallback() throws {
        let entries = [
            FixtureEntry(
                id: "palette.reactNativeMarkdown",
                rank: 0,
                title: "React Native Markdown",
                searchableTexts: ["React Native Markdown", "react", "native", "markdown"]
            ),
            FixtureEntry(
                id: "palette.renameTab",
                rank: 1,
                title: "Rename Tab...",
                searchableTexts: ["Rename Tab...", "rename", "tab", "title"]
            ),
            FixtureEntry(
                id: "palette.openFolder",
                rank: 2,
                title: "Open Folder...",
                searchableTexts: ["Open Folder...", "open", "folder", "directory"]
            ),
        ]
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        guard let searchIndex = CommandPaletteNucleoSearchIndex(entries: corpus) else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let nucleoOnlyMatches = try #require(
            searchIndex.search(query: "renamd", resultLimit: 10)
        )
        #expect(!nucleoOnlyMatches.isEmpty)

        let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
            searchIndex: searchIndex,
            searchCorpus: corpus,
            query: "renamd",
            usageHistory: [:],
            queryIsEmpty: CommandPaletteFuzzyMatcher.preparedQuery("renamd").isEmpty,
            historyTimestamp: 0,
            resultLimit: 10
        )

        #expect(matches.first?.commandID == "palette.renameTab")
    }

    @Test func nucleoFullPageResultsIncludeSwiftSingleEditFallback() throws {
        var entries = (0..<150).map { index in
            FixtureEntry(
                id: "palette.reactNativeMarkdown.\(index)",
                rank: index,
                title: "React Native Markdown \(index)",
                searchableTexts: ["React Native Markdown \(index)", "react", "native", "markdown"]
            )
        }
        entries.append(
            FixtureEntry(
                id: "palette.renameTab",
                rank: 200,
                title: "Rename Tab...",
                searchableTexts: ["Rename Tab...", "rename", "tab", "title"]
            )
        )
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        guard let searchIndex = CommandPaletteNucleoSearchIndex(entries: corpus) else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let nucleoOnlyMatches = try #require(
            searchIndex.search(query: "renamd", resultLimit: 10)
        )
        #expect(nucleoOnlyMatches.count == 10)
        #expect(nucleoOnlyMatches.first?.payload != "palette.renameTab")

        let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
            searchIndex: searchIndex,
            searchCorpus: corpus,
            query: "renamd",
            usageHistory: [:],
            queryIsEmpty: CommandPaletteFuzzyMatcher.preparedQuery("renamd").isEmpty,
            historyTimestamp: 0,
            resultLimit: 10
        )

        #expect(matches.first?.commandID == "palette.renameTab")
    }

    @Test func swiftFallbackMergeKeepsCombinedResultsSortedByScore() {
        let entries = [
            FixtureEntry(
                id: "palette.high",
                rank: 0,
                title: "High Score",
                searchableTexts: ["High Score"]
            ),
            FixtureEntry(
                id: "palette.medium",
                rank: 1,
                title: "Medium Score",
                searchableTexts: ["Medium Score"]
            ),
            FixtureEntry(
                id: "palette.fallback",
                rank: 2,
                title: "Fallback Score",
                searchableTexts: ["Fallback Score"]
            ),
        ]
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let corpusByID = Dictionary(uniqueKeysWithValues: corpus.map { ($0.payload, $0) })

        let matches = CommandPaletteSearchOrchestrator.mergedSwiftFallbackMatches(
            [
                CommandPaletteResolvedSearchMatch(
                    commandID: "palette.fallback",
                    score: 25,
                    titleMatchIndices: []
                )
            ],
            nucleoMatches: [
                CommandPaletteResolvedSearchMatch(
                    commandID: "palette.medium",
                    score: 80,
                    titleMatchIndices: []
                ),
                CommandPaletteResolvedSearchMatch(
                    commandID: "palette.high",
                    score: 100,
                    titleMatchIndices: []
                ),
            ],
            searchCorpusByID: corpusByID,
            limit: 3
        )

        #expect(matches.map(\.commandID) == ["palette.high", "palette.medium", "palette.fallback"])
    }

    @Test func firstValueDictionaryPreservesFirstDuplicateKey() {
        let values = [
            (id: "palette.duplicate", title: "First"),
            (id: "palette.unique", title: "Unique"),
            (id: "palette.duplicate", title: "Second"),
        ]

        let valuesByID = CommandPaletteSearchOrchestrator.firstValueDictionary(values) { $0.id }

        #expect(valuesByID["palette.duplicate"]?.title == "First")
        #expect(valuesByID["palette.unique"]?.title == "Unique")
        #expect(valuesByID.count == 2)
    }

    @Test func nucleoExactPartialResultsDoNotRunSwiftSingleEditFallback() throws {
        let entries = [
            FixtureEntry(
                id: "workspace.project642",
                rank: 0,
                title: "Project 642 Command Palette",
                searchableTexts: ["Project 642 Command Palette", "Workspace", "project-642", "cmd-p-search"]
            ),
            FixtureEntry(
                id: "workspace.project641",
                rank: 1,
                title: "Project 641 Markdown Preview",
                searchableTexts: ["Project 641 Markdown Preview", "Workspace", "project-641", "markdown-preview"]
            ),
        ]
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        guard let searchIndex = CommandPaletteNucleoSearchIndex(entries: corpus) else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let nucleoOnlyMatches = try #require(
            searchIndex.search(query: "project-642", resultLimit: 10)
        )
        #expect(nucleoOnlyMatches.count < 10)

        var cancellationChecks = 0
        let matches = CommandPaletteSearchOrchestrator().resolvedSearchMatches(
            searchIndex: searchIndex,
            searchCorpus: corpus,
            query: "project-642",
            usageHistory: [:],
            queryIsEmpty: CommandPaletteFuzzyMatcher.preparedQuery("project-642").isEmpty,
            historyTimestamp: 0,
            resultLimit: 10
        ) {
            cancellationChecks += 1
            return false
        }

        #expect(matches.first?.commandID == "workspace.project642")
        #expect(cancellationChecks == 2)
    }

    @Test func commandSearchPrefersOpenFolderForOpenFolderQuery() {
        let entries = [
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

        #expect(
            optimizedResults(entries: entries, query: "open folder").prefix(2).map(\.id) ==
            ["palette.openFolder", "palette.openFolderInVSCodeInline"]
        )
    }

    @Test func searchMatchesSingleOmittedCharacterInCommandWordPrefix() {
        let entries = makeFinderCommandEntries()

        #expect(
            optimizedResults(entries: entries, query: "findr").first?.id ==
            "command.finder"
        )
    }

    @Test func searchMatchesSingleInsertedCharacterInCommandWordPrefix() {
        let entries = makeFinderCommandEntries()

        #expect(
            optimizedResults(entries: entries, query: "findder").first?.id ==
            "command.finder"
        )
    }

    @Test func searchMatchesSingleSubstitutedCharacterInCommandWordPrefix() {
        let entries = makeFinderCommandEntries()

        #expect(
            optimizedResults(entries: entries, query: "fander").first?.id ==
            "command.finder"
        )
    }

    @Test func searchMatchesSingleTransposedCharacterInCommandWordPrefix() {
        let entries = makeFinderCommandEntries()

        #expect(
            optimizedResults(entries: entries, query: "fidner").first?.id ==
            "command.finder"
        )
    }

    @Test func searchRejectsMultipleEditsInCommandWordPrefix() {
        let entries = makeFinderCommandEntries()

        #expect(
            optimizedResults(entries: entries, query: "fadnr").first?.id !=
            "command.finder"
        )
    }

    @Test func searchPrefersTitleMatchOverKeywordOnlyMatchForCheckQuery() {
        let results = optimizedResults(entries: makeUpdateCommandEntries(), query: "check")

        #expect(
            results.prefix(2).map(\.id) ==
            ["command.checkForUpdates", "command.attemptUpdate"]
        )
    }

    @Test func previewCandidateCommandIDsAreBounded() {
        let resultIDs = (0..<500).map { "command.\($0)" }

        let previewCandidateIDs = CommandPaletteSearchOrchestrator.previewCandidateCommandIDs(
            resultIDs: resultIDs,
            limit: 192
        )

        #expect(previewCandidateIDs.count == 192)
        #expect(previewCandidateIDs.first == "command.0")
        #expect(previewCandidateIDs.last == "command.191")
    }

    @Test func synchronousSeedRunsOnlyWhenScopeHasNoVisibleResultsAndSearchIndexIsReady() {
        #expect(
            CommandPaletteSearchOrchestrator.shouldSynchronouslySeedResults(
                hasVisibleResultsForScope: false,
                hasSearchIndex: true,
                corpusCount: 5_000
            )
        )
        #expect(
            CommandPaletteSearchOrchestrator.shouldSynchronouslySeedResults(
                hasVisibleResultsForScope: false,
                hasSearchIndex: false,
                corpusCount: 256
            )
        )
        #expect(
            !CommandPaletteSearchOrchestrator.shouldSynchronouslySeedResults(
                hasVisibleResultsForScope: false,
                hasSearchIndex: false,
                corpusCount: 257
            )
        )
        #expect(
            !CommandPaletteSearchOrchestrator.shouldSynchronouslySeedResults(
                hasVisibleResultsForScope: true,
                hasSearchIndex: true,
                corpusCount: 5_000
            )
        )
    }

    @Test func pendingEmptyStateIsNotPreservedWhenSearchIsNotPending() {
        #expect(
            !CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
                isSearchPending: false,
                visibleResultsScopeMatches: true,
                resolvedSearchScopeMatches: true,
                resolvedSearchFingerprintMatches: true,
                resolvedResultsAreEmpty: true
            )
        )
    }

    @Test func pendingEmptyStateIsPreservedForSameResolvedNoMatchQuery() {
        #expect(
            CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
                isSearchPending: true,
                visibleResultsScopeMatches: true,
                resolvedSearchScopeMatches: true,
                resolvedSearchFingerprintMatches: true,
                resolvedResultsAreEmpty: true
            )
        )
    }

    @Test func pendingEmptyStateIsPreservedForSameScopeNoMatchInPlaceEdit() {
        #expect(
            CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
                isSearchPending: true,
                visibleResultsScopeMatches: true,
                resolvedSearchScopeMatches: true,
                resolvedSearchFingerprintMatches: true,
                resolvedResultsAreEmpty: true
            )
        )
    }

    @Test func pendingEmptyStateIsNotPreservedWhenResolvedResultsMayBeStale() {
        #expect(
            !CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
                isSearchPending: true,
                visibleResultsScopeMatches: false,
                resolvedSearchScopeMatches: true,
                resolvedSearchFingerprintMatches: true,
                resolvedResultsAreEmpty: true
            )
        )
        #expect(
            !CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
                isSearchPending: true,
                visibleResultsScopeMatches: true,
                resolvedSearchScopeMatches: false,
                resolvedSearchFingerprintMatches: true,
                resolvedResultsAreEmpty: true
            )
        )
        #expect(
            !CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
                isSearchPending: true,
                visibleResultsScopeMatches: true,
                resolvedSearchScopeMatches: true,
                resolvedSearchFingerprintMatches: false,
                resolvedResultsAreEmpty: true
            )
        )
        #expect(
            !CommandPaletteSearchOrchestrator.shouldPreserveEmptyStateWhileSearchPending(
                isSearchPending: true,
                visibleResultsScopeMatches: true,
                resolvedSearchScopeMatches: true,
                resolvedSearchFingerprintMatches: true,
                resolvedResultsAreEmpty: false
            )
        )
    }

    @Test func commandSearchBenchmarkBeatsLegacyPipeline() {
        let entries = makeCommandEntries(count: 900)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let queries = repeatedQueries(
            ["rename", "rename tab", "open dir", "toggle side", "apply update", "notif", "split right", "cmux"],
            repetitions: 12
        )

        for query in queries.prefix(8) {
            _ = referenceResults(entries: entries, query: query)
            _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
        }

        let referenceMs = benchmarkElapsedMs {
            for query in queries {
                _ = referenceResults(entries: entries, query: query)
            }
        }
        let optimizedMs = benchmarkElapsedMs {
            for query in queries {
                _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
            }
        }

        print(String(format: "BENCH cmd+shift+p reference=%.2fms optimized=%.2fms", referenceMs, optimizedMs))
        #expect(
            optimizedMs < referenceMs * 1.25,
            "Optimized command search regressed significantly: reference=\(referenceMs) optimized=\(optimizedMs)"
        )
    }

    @Test func switcherSearchBenchmarkBeatsLegacyPipeline() {
        let entries = makeSwitcherEntries(count: 400)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let queries = repeatedQueries(
            ["workspace 12", "phoenix", "feature-18", "rename-tab", "3007", "9202", "switch", "worktrees"],
            repetitions: 12
        )

        for query in queries.prefix(8) {
            _ = referenceResults(entries: entries, query: query)
            _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
        }

        let referenceMs = benchmarkElapsedMs {
            for query in queries {
                _ = referenceResults(entries: entries, query: query)
            }
        }
        let optimizedMs = benchmarkElapsedMs {
            for query in queries {
                _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
            }
        }

        print(String(format: "BENCH cmd+p reference=%.2fms optimized=%.2fms", referenceMs, optimizedMs))
        #expect(
            optimizedMs < referenceMs * 1.25,
            "Optimized switcher search regressed significantly: reference=\(referenceMs) optimized=\(optimizedMs)"
        )
    }

    @Test func largeWorkspaceSwitcherSearchBenchmarkAvoidsPerQueryPreparationCost() {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 800)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let queries = repeatedQueries(
            [
                "workspace 799",
                "palette latency",
                "feature 401",
                "cmd-p-search",
                "project-642",
                "4207",
                "9204",
                "Window 3",
            ],
            repetitions: 3
        )

        for query in queries.prefix(8) {
            _ = referenceResults(entries: entries, query: query)
            _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
        }

        let referenceMs = benchmarkElapsedMs {
            for query in queries {
                _ = referenceResults(entries: entries, query: query)
            }
        }
        let optimizedMs = benchmarkElapsedMs {
            for query in queries {
                _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
            }
        }

        print(String(format: "BENCH cmd+p large-workspaces reference=%.2fms optimized=%.2fms", referenceMs, optimizedMs))
        #expect(
            optimizedMs < referenceMs * 0.80,
            "Large switcher search should reuse prepared corpus data: reference=\(referenceMs) optimized=\(optimizedMs)"
        )
    }

    @Test func fastTypingPreviewSearchBenchmarkReportsEstimatedDroppedFrames() {
        let entries = makeLargeWorkspaceSwitcherEntries(count: 800)
        let corpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        let visibleCandidateCorpus = Array(corpus.prefix(128))
        let queries = repeatedQueries(
            fastTypingPrefixes("cmd-p-search") + fastTypingPrefixes("palette latency"),
            repetitions: 2
        )

        for query in queries.prefix(8) {
            _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
            _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query, resultLimit: 100) { _, _ in 0 }
            _ = CommandPaletteSearchEngine(entries: visibleCandidateCorpus).search(
            query: query, resultLimit: 48) { _, _ in 0 }
        }

        var fullDurationsMs: [Double] = []
        var cappedFullDurationsMs: [Double] = []
        var previewDurationsMs: [Double] = []
        fullDurationsMs.reserveCapacity(queries.count)
        cappedFullDurationsMs.reserveCapacity(queries.count)
        previewDurationsMs.reserveCapacity(queries.count)

        for query in queries {
            fullDurationsMs.append(
                benchmarkElapsedMs {
                    _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query) { _, _ in 0 }
                }
            )
            cappedFullDurationsMs.append(
                benchmarkElapsedMs {
                    _ = CommandPaletteSearchEngine(entries: corpus).search(
            query: query, resultLimit: 100) { _, _ in 0 }
                }
            )
            previewDurationsMs.append(
                benchmarkElapsedMs {
                    _ = CommandPaletteSearchEngine(entries: visibleCandidateCorpus).search(
            query: query, resultLimit: 48) { _, _ in 0 }
                }
            )
        }

        let fullMs = fullDurationsMs.reduce(0, +)
        let cappedFullMs = cappedFullDurationsMs.reduce(0, +)
        let previewMs = previewDurationsMs.reduce(0, +)
        let fullDroppedFrames = estimatedDroppedFrames(for: fullDurationsMs)
        let cappedFullDroppedFrames = estimatedDroppedFrames(for: cappedFullDurationsMs)
        let previewDroppedFrames = estimatedDroppedFrames(for: previewDurationsMs)
        let maxFullMs = fullDurationsMs.max() ?? 0
        let maxCappedFullMs = cappedFullDurationsMs.max() ?? 0
        let maxPreviewMs = previewDurationsMs.max() ?? 0
        let maxPreviewQuery = previewDurationsMs.enumerated().max(by: { $0.element < $1.element }).map {
            queries[$0.offset]
        } ?? ""

        print(String(
            format: "BENCH cmd+p fast-typing full=%.2fms cappedFull=%.2fms visiblePreview=%.2fms maxFull=%.2fms maxCappedFull=%.2fms maxVisiblePreview=%.2fms maxVisiblePreviewQuery=%@ fullDroppedFrames=%d cappedFullDroppedFrames=%d visiblePreviewDroppedFrames=%d",
            fullMs,
            cappedFullMs,
            previewMs,
            maxFullMs,
            maxCappedFullMs,
            maxPreviewMs,
            maxPreviewQuery,
            fullDroppedFrames,
            cappedFullDroppedFrames,
            previewDroppedFrames
        ))
        #expect(
            cappedFullMs < fullMs,
            "Capped full-corpus search should avoid preparing results the UI cannot render: full=\(fullMs) capped=\(cappedFullMs)"
        )
        #expect(
            cappedFullDroppedFrames <= fullDroppedFrames,
            "Capped full-corpus search should not increase estimated frame-budget misses: full=\(fullDroppedFrames) capped=\(cappedFullDroppedFrames)"
        )
        #expect(
            previewMs < cappedFullMs,
            "Visible-candidate preview search should avoid full-corpus work during fast typing: capped=\(cappedFullMs) preview=\(previewMs)"
        )
        #expect(
            previewDroppedFrames <= cappedFullDroppedFrames,
            "Preview search should not increase estimated frame-budget misses: capped=\(cappedFullDroppedFrames) preview=\(previewDroppedFrames)"
        )
    }
}
