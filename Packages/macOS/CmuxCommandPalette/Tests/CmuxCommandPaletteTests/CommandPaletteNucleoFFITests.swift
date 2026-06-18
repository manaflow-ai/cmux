import Foundation
import Testing

@testable import CmuxCommandPalette

// Serialized: the comparison/overhead tests assert on wall-clock benchmark
// numbers, which parallel execution would skew.
@Suite(.serialized)
struct CommandPaletteNucleoFFITests {
    @Test func nucleoFFIPrefersOpenFolderForOpenFolderQuery() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        #expect(library.version() == 2)
        let entries = makeOpenFolderEntries()
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "open folder", limit: 4).map(\.id)

        #expect(
            Array(resultIDs.prefix(2)) ==
            ["palette.openFolder", "palette.openFolderInVSCodeInline"]
        )
    }

    @Test func nucleoFFIMatchesMultiTokenQueriesAcrossFieldsWithoutOrderDependency() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = makeOpenFolderEntries()
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "directory open", limit: 4).map(\.id)

        #expect(
            Array(resultIDs.prefix(2)) ==
            ["palette.openFolder", "palette.openFolderInVSCodeInline"]
        )
    }

    @Test func nucleoFFIPrefersTitleInitialismOverCompactInWordMatch() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = makeInitialismWorkspaceEntries()
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "ims", limit: 5).map(\.id)

        #expect(resultIDs.first == "workspace.indigoMarkdownStudio")
    }

    @Test func nucleoFFIPrefersExactAliasOverTitleInitialism() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = [
            FixtureEntry(
                id: "palette.openWorkspacePRLinks",
                rank: 0,
                title: "Open All Workspace PR Links",
                searchableTexts: [
                    "Open All Workspace PR Links",
                    "Workspace",
                    "pull",
                    "request",
                    "review",
                    "merge",
                    "pr",
                    "mr",
                    "open",
                    "links",
                    "workspace",
                ]
            ),
            FixtureEntry(
                id: "palette.markWorkspaceRead",
                rank: 1,
                title: "Mark Workspace as Read",
                searchableTexts: ["Mark Workspace as Read", "Workspace", "workspace", "read", "notification"]
            ),
        ]
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "mr", limit: 5).map(\.id)

        #expect(resultIDs.first == "palette.openWorkspacePRLinks")
    }

    @Test func nucleoFFIPrefersTitleMatchOverLongExactKeyword() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = [
            FixtureEntry(
                id: "palette.checkForUpdates",
                rank: 0,
                title: "Check for Updates",
                searchableTexts: ["Check for Updates", "Global", "update", "upgrade", "release"]
            ),
            FixtureEntry(
                id: "palette.attemptUpdate",
                rank: 1,
                title: "Attempt Update",
                searchableTexts: ["Attempt Update", "Global", "attempt", "check", "update", "upgrade", "release"]
            ),
        ]
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "check", limit: 5).map(\.id)

        #expect(resultIDs.first == "palette.checkForUpdates")
    }

    @Test func nucleoFFIPrefersVisibleTitlePrefixOverHiddenMetadataKeyword() throws {
        // Regression: in the workspace switcher, a workspace whose visible title starts with the
        // query must rank above one that only matched a hidden metadata token (a branch or
        // description word produced by commandPaletteWorkspaceSearchMetadata). For short queries
        // an exact match on such a hidden line scored 30_030 and beat the visible title prefix,
        // which only reached nucleo(~88) + 2_000. The "ios" row shown to the user therefore had
        // no highlighted title yet sat at the top. https://github.com/manaflow-ai/cmux/pull/5148
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = [
            FixtureEntry(
                id: "workspace.iosMobileTerminal",
                rank: 0,
                title: "iOS Mobile Terminal",
                searchableTexts: ["iOS Mobile Terminal", "Workspace", "workspace", "switch", "go"]
            ),
            FixtureEntry(
                id: "workspace.forkSessionNotFound",
                rank: 1,
                title: "Fork Session Not Found",
                // "ios" here stands in for a hidden branch/description token, the field that the
                // switcher indexes but never highlights in the row.
                searchableTexts: [
                    "Fork Session Not Found", "Workspace", "workspace", "switch", "go",
                    "branch", "ios",
                ]
            ),
        ]
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "ios", limit: 5).map(\.id)

        #expect(resultIDs.first == "workspace.iosMobileTerminal")
        #expect(resultIDs.contains("workspace.forkSessionNotFound"))
    }

    @Test func nucleoFFIPrefersTitleOverSummedHiddenKeywordsForMultiTokenQuery() throws {
        // Regression: the per-token keyword path is summed, so a multi-token query like "ios app"
        // can give a hidden row an exact line per token (~30_030 each, ~60_060 summed) that beats a
        // flat title-literal score. The title tier is scaled by query token count so a visible
        // title match still wins for multi-token queries.
        // https://github.com/manaflow-ai/cmux/pull/5148
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = [
            FixtureEntry(
                id: "workspace.iosApp",
                rank: 0,
                title: "iOS App",
                searchableTexts: ["iOS App", "Workspace", "workspace", "switch", "go"]
            ),
            FixtureEntry(
                id: "workspace.hiddenMetadataRow",
                rank: 1,
                title: "Some Unrelated Workspace",
                // Both query tokens present only as hidden metadata tokens (branch/description).
                searchableTexts: [
                    "Some Unrelated Workspace", "Workspace", "workspace", "switch", "go",
                    "branch", "ios", "app",
                ]
            ),
        ]
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "ios app", limit: 5).map(\.id)

        #expect(resultIDs.first == "workspace.iosApp")
    }

    @Test func nucleoFFIPrefersDiacriticTitlePrefixOverHiddenKeyword() throws {
        // Regression: the literal-title check must use the matcher's case + Smart diacritic
        // normalization, so a localized title like "Éclair" is recognized as a prefix of "e" and
        // still beats a row that only has a hidden exact "e" metadata token.
        // https://github.com/manaflow-ai/cmux/pull/5148
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = [
            FixtureEntry(
                id: "workspace.eclair",
                rank: 0,
                title: "Éclair Notes",
                searchableTexts: ["Éclair Notes", "Workspace", "workspace", "switch", "go"]
            ),
            FixtureEntry(
                id: "workspace.hiddenEKeyword",
                rank: 1,
                title: "Some Other Workspace",
                searchableTexts: [
                    "Some Other Workspace", "Workspace", "workspace", "switch", "go", "branch", "e",
                ]
            ),
        ]
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "e", limit: 5).map(\.id)

        #expect(resultIDs.first == "workspace.eclair")
    }

    @Test func nucleoFFIDoesNotMatchSingleTokenAcrossSearchFields() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = [
            FixtureEntry(
                id: "palette.crossFieldOnly",
                rank: 0,
                title: "Other Command",
                searchableTexts: ["Other Command", "foo", "bar"]
            ),
            FixtureEntry(
                id: "palette.frameRate",
                rank: 1,
                title: "Frame Rate",
                searchableTexts: ["Frame Rate", "Display", "frame", "rate"]
            ),
        ]
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "fr", limit: 5).map(\.id)

        #expect(resultIDs.first == "palette.frameRate")
        #expect(!resultIDs.contains("palette.crossFieldOnly"))
    }

    @Test func nucleoFFIMatchesAsciiQueryAgainstDiacriticTitle() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = [
            FixtureEntry(
                id: "workspace.cafe",
                rank: 0,
                title: "Café Notes",
                searchableTexts: ["Café Notes", "Workspace"]
            ),
            FixtureEntry(
                id: "workspace.cargo",
                rank: 1,
                title: "Cargo Notes",
                searchableTexts: ["Cargo Notes", "Workspace"]
            ),
        ]
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "cafe", limit: 5).map(\.id)

        #expect(resultIDs.first == "workspace.cafe")
    }

    @Test func nucleoFFIHandlesEmptyQuery() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = makeOpenFolderEntries()
        let index = try NucleoIndex(library: library, entries: entries)

        let resultIDs = try index.search(query: "", limit: 3).map(\.id)

        #expect(resultIDs == ["palette.newWorkspace", "palette.newWindow", "palette.openFolder"])
    }

    @Test func nucleoFFIFindsDeepWorkspaceMatch() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = makeLargeWorkspaceSwitcherEntries(count: 5_000)
        let index = try NucleoIndex(library: library, entries: entries)

        let results = try index.search(query: "workspace 4913", limit: 10)

        #expect(results.first?.id == "workspace.large.4913")
        #expect(results.count <= 10)
    }

    @Test func productionNucleoSearchIndexFindsCommandPaletteCommands() throws {
        let entries = makeOpenFolderEntries()
        let corpus = searchCorpus(entries: entries)
        guard let index = CommandPaletteNucleoSearchIndex(entries: corpus) else { return }
        // Skipped: nucleo FFI dylib not built in this environment.

        let resultIDs = index.search(
            query: "open folder",
            resultLimit: 4,
            historyBoost: { _, _ in 0 }
        )?.map(\.payload)

        #expect(
            Array((resultIDs ?? []).prefix(2)) ==
            ["palette.openFolder", "palette.openFolderInVSCodeInline"]
        )
    }

    @Test func productionNucleoSearchIndexAppliesHistoryBoostBeforeLimiting() throws {
        let entries = makeOpenFolderEntries()
        let corpus = searchCorpus(entries: entries)
        guard let index = CommandPaletteNucleoSearchIndex(entries: corpus) else { return }
        // Skipped: nucleo FFI dylib not built in this environment.

        let results = index.search(
            query: "",
            resultLimit: 1,
            historyBoost: { commandID, _ in commandID == "palette.openFolder" ? 600 : 0 }
        )

        #expect(results?.map(\.payload) == ["palette.openFolder"])
    }

    @Test func nucleoFFILargeWorkspacePerformanceAndCorrectnessComparison() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = makeLargeWorkspaceSwitcherEntries(count: 800)
        let corpus = searchCorpus(entries: entries)
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

        var index: NucleoIndex?
        let buildMs = benchmarkElapsedMs {
            index = try? NucleoIndex(library: library, entries: entries)
        }
        let nucleoIndex = try #require(index)

        for query in queries.prefix(8) {
            _ = optimizedResults(corpus: corpus, query: query, resultLimit: 100)
            _ = try nucleoIndex.search(query: query, limit: 100)
        }

        let optimizedMs = benchmarkElapsedMs {
            for query in queries {
                _ = optimizedResults(corpus: corpus, query: query, resultLimit: 100)
            }
        }
        let nucleoMs = benchmarkElapsedMs {
            for query in queries {
                _ = try? nucleoIndex.search(query: query, limit: 100)
            }
        }

        let comparison = try correctnessComparison(
            corpus: corpus,
            queries: Array(Set(queries)).sorted(),
            index: nucleoIndex,
            resultLimit: 20
        )
        print(String(
            format: "BENCH cmd+p nucleo-ffi large-workspaces build=%.2fms swiftOptimized=%.2fms nucleo=%.2fms top1Agreement=%d/%d meanTop10Overlap=%.2f",
            buildMs,
            optimizedMs,
            nucleoMs,
            comparison.top1Agreement,
            comparison.queryCount,
            comparison.meanTop10Overlap
        ))
        if !comparison.top1Mismatches.isEmpty {
            print("CHECK cmd+p nucleo-ffi top1Mismatches \(comparison.top1Mismatches.joined(separator: "; "))")
        }

        #expect(comparison.queryCount > 0)
        #expect(nucleoMs > 0)
    }

    @Test func nucleoFFIFastTypingFrameBudgetComparison() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = makeLargeWorkspaceSwitcherEntries(count: 800)
        let previewEntries = Array(entries.prefix(128))
        let corpus = searchCorpus(entries: entries)
        let previewCorpus = searchCorpus(entries: previewEntries)
        let fullIndex = try NucleoIndex(library: library, entries: entries)
        let previewIndex = try NucleoIndex(library: library, entries: previewEntries)
        let queries = repeatedQueries(
            fastTypingPrefixes("cmd-p-search") + fastTypingPrefixes("palette latency"),
            repetitions: 2
        )

        for query in queries.prefix(8) {
            _ = optimizedResults(corpus: corpus, query: query, resultLimit: 100)
            _ = optimizedResults(corpus: previewCorpus, query: query, resultLimit: 48)
            _ = try fullIndex.search(query: query, limit: 100)
            _ = try previewIndex.search(query: query, limit: 48)
        }

        var swiftFullDurationsMs: [Double] = []
        var swiftPreviewDurationsMs: [Double] = []
        var nucleoFullDurationsMs: [Double] = []
        var nucleoPreviewDurationsMs: [Double] = []
        swiftFullDurationsMs.reserveCapacity(queries.count)
        swiftPreviewDurationsMs.reserveCapacity(queries.count)
        nucleoFullDurationsMs.reserveCapacity(queries.count)
        nucleoPreviewDurationsMs.reserveCapacity(queries.count)

        for query in queries {
            swiftFullDurationsMs.append(
                benchmarkElapsedMs {
                    _ = optimizedResults(corpus: corpus, query: query, resultLimit: 100)
                }
            )
            swiftPreviewDurationsMs.append(
                benchmarkElapsedMs {
                    _ = optimizedResults(corpus: previewCorpus, query: query, resultLimit: 48)
                }
            )
            nucleoFullDurationsMs.append(
                benchmarkElapsedMs {
                    _ = try? fullIndex.search(query: query, limit: 100)
                }
            )
            nucleoPreviewDurationsMs.append(
                benchmarkElapsedMs {
                    _ = try? previewIndex.search(query: query, limit: 48)
                }
            )
        }

        print(String(
            format: "BENCH cmd+p nucleo-ffi fast-typing swiftFull=%.2fms swiftPreview=%.2fms nucleoFull=%.2fms nucleoPreview=%.2fms maxSwiftFull=%.2fms maxSwiftPreview=%.2fms maxNucleoFull=%.2fms maxNucleoPreview=%.2fms swiftFullDroppedFrames=%d swiftPreviewDroppedFrames=%d nucleoFullDroppedFrames=%d nucleoPreviewDroppedFrames=%d",
            swiftFullDurationsMs.reduce(0, +),
            swiftPreviewDurationsMs.reduce(0, +),
            nucleoFullDurationsMs.reduce(0, +),
            nucleoPreviewDurationsMs.reduce(0, +),
            swiftFullDurationsMs.max() ?? 0,
            swiftPreviewDurationsMs.max() ?? 0,
            nucleoFullDurationsMs.max() ?? 0,
            nucleoPreviewDurationsMs.max() ?? 0,
            estimatedDroppedFrames(for: swiftFullDurationsMs),
            estimatedDroppedFrames(for: swiftPreviewDurationsMs),
            estimatedDroppedFrames(for: nucleoFullDurationsMs),
            estimatedDroppedFrames(for: nucleoPreviewDurationsMs)
        ))

        #expect(
            estimatedDroppedFrames(for: nucleoPreviewDurationsMs) <=
            estimatedDroppedFrames(for: nucleoFullDurationsMs)
        )
    }

    @Test func nucleoFFIEdgeCaseTypingFrameBudgetComparison() throws {
        let entries = makeEdgeCasePaletteEntries(generatedWorkspaceCount: 2_000)
        let corpus = searchCorpus(entries: entries)
        var index: CommandPaletteNucleoSearchIndex<String>?
        let buildMs = benchmarkElapsedMs {
            index = CommandPaletteNucleoSearchIndex(entries: corpus)
        }
        guard let productionIndex = index else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let queries = repeatedQueries(edgeCaseTypingQueries(), repetitions: 2)

        for query in queries.prefix(16) {
            _ = optimizedResults(corpus: corpus, query: query, resultLimit: 100)
            _ = productionIndex.search(query: query, resultLimit: 100)
        }

        var swiftDurationsMs: [Double] = []
        var nucleoDurationsMs: [Double] = []
        var boostedNucleoDurationsMs: [Double] = []
        swiftDurationsMs.reserveCapacity(queries.count)
        nucleoDurationsMs.reserveCapacity(queries.count)
        boostedNucleoDurationsMs.reserveCapacity(queries.count)

        for query in queries {
            swiftDurationsMs.append(
                benchmarkElapsedMs {
                    _ = optimizedResults(corpus: corpus, query: query, resultLimit: 100)
                }
            )
            nucleoDurationsMs.append(
                benchmarkElapsedMs {
                    _ = productionIndex.search(query: query, resultLimit: 100)
                }
            )
            boostedNucleoDurationsMs.append(
                benchmarkElapsedMs {
                    _ = productionIndex.search(
                        query: query,
                        resultLimit: 100,
                        historyBoost: { commandID, queryIsEmpty in
                            if commandID == "palette.markWorkspaceUnread" {
                                return queryIsEmpty ? 300 : 120
                            }
                            return 0
                        }
                    )
                }
            )
        }

        let expectedTopResults = [
            ("ims", "workspace.indigoMarkdownStudio"),
            ("wunr", "palette.markWorkspaceUnread"),
            ("open folder", "palette.openFolder"),
            ("workspace 1901", "workspace.large.1901"),
            ("cafe", "workspace.cafeUnicodeNotes"),
        ]
        for (query, expectedID) in expectedTopResults {
            #expect(
                productionIndex.search(query: query, resultLimit: 10)?.first?.payload == expectedID,
                "Unexpected top result for \(query)"
            )
        }

        print(String(
            format: "BENCH cmd+p nucleo-ffi edge-typing entries=%d queries=%d build=%.2fms swift=%.2fms nucleo=%.2fms boostedNucleo=%.2fms maxSwift=%.2fms p95Swift=%.2fms maxNucleo=%.2fms p95Nucleo=%.2fms maxBoostedNucleo=%.2fms p95BoostedNucleo=%.2fms swiftDroppedFrames=%d nucleoDroppedFrames=%d boostedNucleoDroppedFrames=%d",
            entries.count,
            queries.count,
            buildMs,
            swiftDurationsMs.reduce(0, +),
            nucleoDurationsMs.reduce(0, +),
            boostedNucleoDurationsMs.reduce(0, +),
            swiftDurationsMs.max() ?? 0,
            percentile(swiftDurationsMs, percentile: 0.95),
            nucleoDurationsMs.max() ?? 0,
            percentile(nucleoDurationsMs, percentile: 0.95),
            boostedNucleoDurationsMs.max() ?? 0,
            percentile(boostedNucleoDurationsMs, percentile: 0.95),
            estimatedDroppedFrames(for: swiftDurationsMs),
            estimatedDroppedFrames(for: nucleoDurationsMs),
            estimatedDroppedFrames(for: boostedNucleoDurationsMs)
        ))

        #expect(
            estimatedDroppedFrames(for: nucleoDurationsMs) <=
            estimatedDroppedFrames(for: swiftDurationsMs)
        )
    }

    @Test func nucleoFFICallOverheadBenchmark() throws {
        guard let library = try NucleoLibrary.loadIfAvailable() else { return }
        // Skipped: nucleo FFI dylib not built in this environment.
        let entries = makeLargeWorkspaceSwitcherEntries(count: 800)
        let corpus = searchCorpus(entries: entries)
        let rawIndex = try NucleoIndex(library: library, entries: entries)
        let productionIndex = try #require(CommandPaletteNucleoSearchIndex(entries: corpus))
        let noopIterations = 50_000
        let searchIterations = 200
        let queryBytes = Array("cmd-p-search".utf8)
        var ffiNoopFailures = 0

        var outCount = 0
        let ffiNoopMs = benchmarkElapsedMs {
            for _ in 0..<noopIterations {
                let status = queryBytes.withUnsafeBufferPointer { queryBuffer in
                    library.searchIndex(
                        rawIndex.pointer,
                        queryBuffer.baseAddress,
                        queryBuffer.count,
                        0,
                        nil,
                        0,
                        &outCount
                    )
                }
                if status != 0 { ffiNoopFailures += 1 }
            }
        }

        let rawSearchMs = benchmarkElapsedMs {
            for _ in 0..<searchIterations {
                _ = try? rawIndex.search(query: "cmd-p-search", limit: 100)
            }
        }
        let productionNoHistoryMs = benchmarkElapsedMs {
            for _ in 0..<searchIterations {
                _ = productionIndex.search(query: "cmd-p-search", resultLimit: 100)
            }
        }
        let productionZeroBoostClosureMs = benchmarkElapsedMs {
            for _ in 0..<searchIterations {
                _ = productionIndex.search(
                    query: "cmd-p-search",
                    resultLimit: 100,
                    historyBoost: { _, _ in 0 }
                )
            }
        }

        print(String(
            format: "BENCH cmd+p nucleo-ffi overhead noopCalls=%d noopTotal=%.2fms noopPerCall=%.3fus rawSearchPerCall=%.3fms prodNoHistoryPerCall=%.3fms prodZeroBoostClosurePerCall=%.3fms",
            noopIterations,
            ffiNoopMs,
            (ffiNoopMs * 1_000.0) / Double(noopIterations),
            rawSearchMs / Double(searchIterations),
            productionNoHistoryMs / Double(searchIterations),
            productionZeroBoostClosureMs / Double(searchIterations)
        ))

        #expect(ffiNoopFailures == 0)
    }
}
