import CmuxMobileRPC
import CmuxMobileShell
import Foundation
import Testing
@testable import CmuxDiffUI

@MainActor
@Suite struct DiffScreenStoreTests {
    @Test func summaryBuildsFileStatesAndRespectsStaticGates() async throws {
        let summaries = [
            file(path: "Sources/App.swift", status: .modified, additions: 2, deletions: 1),
            file(path: "Assets/icon.png", status: .modified, isBinary: true),
            file(path: "Generated/API.swift", status: .modified, additions: 4000, isLarge: true),
            file(path: "New.swift", oldPath: "Old.swift", status: .renamed),
        ]
        let fake = FakeMobileDiffsService(summaries: [.success(summary(files: summaries))])
        let store = try makeStore(fake: fake, name: "summary")

        await store.loadInitial()

        #expect(store.phase == .loaded)
        #expect(store.files.map(\.summary.path) == summaries.map(\.path))
        #expect(store.fileStates.map(\.file.content) == [.loading, .binary, .large, .renameOnly])
    }

    @Test func fileLoadDrainsEveryCursorPage() async throws {
        let first = hunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, text: "one")
        let second = hunk(oldStart: 5, oldLines: 1, newStart: 5, newLines: 1, text: "two")
        let fake = FakeMobileDiffsService(
            summaries: [.success(summary(files: [file(path: "App.swift", additions: 1)]))],
            files: [
                .success(MobileDiffFileResponse(
                    hunks: [first], isBinary: false, tooLarge: false, nextCursor: 7
                )),
                .success(MobileDiffFileResponse(hunks: [second], isBinary: false, tooLarge: false)),
            ]
        )
        let store = try makeStore(fake: fake, name: "paging")
        await store.loadInitial()

        await store.loadFile(path: "App.swift")

        let loaded = try #require(store.fileStates.first?.file.content)
        guard case let .loaded(hunks) = loaded else {
            Issue.record("Expected loaded hunks")
            return
        }
        #expect(hunks == [first, second])
        #expect(await fake.requestedCursors == [nil, 7])
        #expect(await fake.requestedForces == [false, false])
    }

    @Test func largeFileRequiresForceBeforeMakingARequest() async throws {
        let fake = FakeMobileDiffsService(
            summaries: [.success(summary(files: [
                file(path: "Large.swift", additions: 4000, isLarge: true),
            ]))],
            files: [.success(MobileDiffFileResponse(hunks: [], isBinary: false, tooLarge: false))]
        )
        let store = try makeStore(fake: fake, name: "force")
        await store.loadInitial()

        await store.loadFile(path: "Large.swift")
        #expect(await fake.requestedForces.isEmpty)

        await store.loadFile(path: "Large.swift", force: true)
        #expect(await fake.requestedForces == [true])
    }

    @Test func contextExpansionSplicesRowsAndUsesCumulativeHunkDelta() async throws {
        let first = MobileDiffHunk(
            oldStart: 1,
            oldLines: 2,
            newStart: 1,
            newLines: 3,
            rows: [
                MobileDiffRow(kind: .context, text: "a"),
                MobileDiffRow(kind: .add, text: "inserted"),
                MobileDiffRow(kind: .context, text: "b"),
            ]
        )
        let second = MobileDiffHunk(
            oldStart: 6,
            oldLines: 1,
            newStart: 7,
            newLines: 1,
            rows: [MobileDiffRow(kind: .context, text: "target")]
        )
        let fake = FakeMobileDiffsService(
            summaries: [.success(summary(files: [file(path: "App.swift", additions: 1)]))],
            files: [.success(MobileDiffFileResponse(
                hunks: [first, second], isBinary: false, tooLarge: false
            ))],
            contexts: [.success(MobileDiffContextResponse(rows: ["c", "d", "e"]))]
        )
        let store = try makeStore(fake: fake, name: "context")
        await store.loadInitial()
        await store.loadFile(path: "App.swift")

        await store.expandContext(DiffContextExpansionRequest(
            path: "App.swift", hunkIndex: 1, direction: .up
        ))

        #expect(await fake.requestedContextRanges == [4...6])
        let content = try #require(store.fileStates.first?.file.content)
        guard case let .loaded(hunks) = content else {
            Issue.record("Expected context-expanded hunks")
            return
        }
        #expect(hunks[1].oldStart == 3)
        #expect(hunks[1].newStart == 4)
        #expect(hunks[1].oldLines == 4)
        #expect(hunks[1].newLines == 4)
        #expect(hunks[1].rows.prefix(3).map(\.oldNo) == [3, 4, 5])
        #expect(hunks[1].rows.prefix(3).map(\.newNo) == [4, 5, 6])

        let rendered = DiffRowBuilder().rows(path: "App.swift", hunks: [hunks[1]])
        #expect(rendered[1].oldLine == 3 && rendered[1].newLine == 4)
        #expect(rendered[4].oldLine == 6 && rendered[4].newLine == 7)
    }

    @Test(arguments: [
        (MobileDiffsServiceError.unknownWorkspace, DiffScreenErrorKind.unknownWorkspace),
        (MobileDiffsServiceError.notGitRepository, DiffScreenErrorKind.notGitRepository),
        (MobileDiffsServiceError.baselineMissing, DiffScreenErrorKind.baselineMissing),
    ])
    func mapsStructuredSummaryErrors(
        serviceError: MobileDiffsServiceError,
        expected: DiffScreenErrorKind
    ) async throws {
        let fake = FakeMobileDiffsService(summaries: [.serviceFailure(serviceError)])
        let store = try makeStore(fake: fake, name: "error-\(expected)")

        await store.loadInitial()

        #expect(store.phase == .failed(expected))
    }

    @Test func mapsUnexpectedSummaryErrorsToTransport() async throws {
        let fake = FakeMobileDiffsService(summaries: [.transportFailure])
        let store = try makeStore(fake: fake, name: "transport")

        await store.loadInitial()

        #expect(store.phase == .failed(.transport))
    }

    @Test func viewedStatePersistsAcrossSummaryRefetch() async throws {
        let response = summary(files: [file(path: "App.swift", additions: 1, digest: "same")])
        let fake = FakeMobileDiffsService(summaries: [.success(response), .success(response)])
        let store = try makeStore(fake: fake, name: "viewed")
        await store.loadInitial()

        store.toggleViewed(path: "App.swift")
        #expect(store.viewedCount == 1)

        await store.refresh()
        #expect(store.viewedCount == 1)
        #expect(store.fileStates.first?.isViewed == true)
    }

    @Test func layoutOverridePersistsAndAutomaticResolvesByOrientation() throws {
        let defaults = try defaults(name: "layout")
        let fake = FakeMobileDiffsService(summaries: [])
        let store = DiffScreenStore(
            service: fake,
            workspaceRef: "workspace",
            viewedStore: DiffViewedStore(defaults: defaults),
            layoutPreferenceStore: DiffLayoutPreferenceStore(defaults: defaults)
        )
        #expect(store.layoutOverride == .automatic)
        #expect(store.layoutOverride.renderMode(isLandscape: false) == .unified)
        #expect(store.layoutOverride.renderMode(isLandscape: true) == .split)

        store.layoutOverride = .split
        let reloaded = DiffScreenStore(
            service: fake,
            workspaceRef: "workspace",
            viewedStore: DiffViewedStore(defaults: defaults),
            layoutPreferenceStore: DiffLayoutPreferenceStore(defaults: defaults)
        )
        #expect(reloaded.layoutOverride == .split)
    }

    private func makeStore(fake: FakeMobileDiffsService, name: String) throws -> DiffScreenStore {
        let defaults = try defaults(name: name)
        return DiffScreenStore(
            service: fake,
            workspaceRef: "workspace",
            viewedStore: DiffViewedStore(defaults: defaults),
            layoutPreferenceStore: DiffLayoutPreferenceStore(defaults: defaults)
        )
    }

    private func defaults(name: String) throws -> UserDefaults {
        let suite = "DiffScreenStoreTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func summary(files: [MobileDiffFileSummary]) -> MobileDiffSummaryResponse {
        MobileDiffSummaryResponse(
            baseInfo: MobileDiffBaseInfo(kind: .workingTree, resolvedRef: "HEAD", describe: "HEAD"),
            totals: MobileDiffTotals(
                files: files.count,
                additions: files.reduce(0) { $0 + $1.additions },
                deletions: files.reduce(0) { $0 + $1.deletions }
            ),
            files: files,
            truncatedFileCount: 0
        )
    }

    private func file(
        path: String,
        oldPath: String? = nil,
        status: MobileDiffFileStatus = .modified,
        additions: Int = 0,
        deletions: Int = 0,
        isBinary: Bool = false,
        isLarge: Bool = false,
        digest: String = "digest"
    ) -> MobileDiffFileSummary {
        MobileDiffFileSummary(
            path: path,
            oldPath: oldPath,
            status: status,
            additions: additions,
            deletions: deletions,
            isBinary: isBinary,
            isLarge: isLarge,
            patchDigest: digest
        )
    }

    private func hunk(
        oldStart: Int,
        oldLines: Int,
        newStart: Int,
        newLines: Int,
        text: String
    ) -> MobileDiffHunk {
        MobileDiffHunk(
            oldStart: oldStart,
            oldLines: oldLines,
            newStart: newStart,
            newLines: newLines,
            rows: [MobileDiffRow(kind: .context, text: text)]
        )
    }
}
