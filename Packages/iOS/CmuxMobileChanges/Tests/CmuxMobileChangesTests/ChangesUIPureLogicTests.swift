import SwiftUI
import Testing

@testable import CmuxMobileChanges

@Suite struct ChangesUIPureLogicTests {
    @Test @MainActor
    func themeResolvesDistinctLightAndDarkTokens() {
        let light = ChangesTheme(colorScheme: .light)
        let dark = ChangesTheme(colorScheme: .dark)

        #expect(light.additionBackground != dark.additionBackground)
        #expect(light.removalBackground != dark.removalBackground)
        #expect(light.hunkHeaderBackground != dark.hunkHeaderBackground)
    }

    @Test
    func gutterWidthUsesDigitCountAndMeasuredAdvance() {
        let layout = DiffGutterLayout(maximumLineNumber: 9_842)

        #expect(layout.digitCount == 4)
        #expect(layout.width(monospacedDigitAdvance: 7.5) == 34)
    }

    @Test
    func copyHunkAssemblesUnifiedPrefixes() {
        let hunk = DiffHunk(
            header: DiffLine(
                kind: .hunkHeader,
                text: "@@ -1,2 +1,2 @@",
                oldNumber: nil,
                newNumber: nil
            ),
            oldStart: 1,
            oldCount: 2,
            newStart: 1,
            newCount: 2,
            sectionContext: nil,
            lines: [
                DiffLine(kind: .context, text: "let stable = true", oldNumber: 1, newNumber: 1),
                DiffLine(kind: .removal, text: "let value = 1", oldNumber: 2, newNumber: nil),
                DiffLine(kind: .addition, text: "let value = 2", oldNumber: nil, newNumber: 2),
            ]
        )

        #expect(hunk.copyText == """
        @@ -1,2 +1,2 @@
         let stable = true
        -let value = 1
        +let value = 2
        """)
    }

    @Test
    func pagePositionClampsToAvailablePages() {
        #expect(DiffPagerPosition(selectedIndex: 2, pageCount: 7).currentPage == 3)
        #expect(DiffPagerPosition(selectedIndex: 99, pageCount: 7).currentPage == 7)
        #expect(DiffPagerPosition(selectedIndex: 0, pageCount: 0).currentPage == 0)
    }

    @Test(arguments: [
        (FileChangeKind.added, FileChangeBadge.Role.new),
        (.untracked, .new),
        (.deleted, .deleted),
    ])
    func exceptionalKindsCarryBadges(kind: FileChangeKind, role: FileChangeBadge.Role) {
        #expect(kind.badge?.role == role)
        #expect(kind.badge?.text.isEmpty == false)
    }

    @Test(arguments: [FileChangeKind.modified, .renamed, .unknown])
    func ordinaryKindsStayUnbadged(kind: FileChangeKind) {
        #expect(kind.badge == nil)
    }

    @Test(arguments: [
        (FileChangeKind.modified, FileDiffPreviewRevision.current, true),
        (.renamed, .current, true),
        (.deleted, .base, false),
        (.added, .current, false),
        (.untracked, .current, false),
        (.unknown, .current, false),
    ])
    func binaryPreviewPolicy(
        kind: FileChangeKind,
        revision: FileDiffPreviewRevision,
        allowsRevisionSelection: Bool
    ) {
        let policy = FileDiffPreviewPolicy(kind: kind)

        #expect(policy.defaultRevision == revision)
        #expect(policy.allowsRevisionSelection == allowsRevisionSelection)
    }

    @Test func diffContinuationGrowsByFourAndSaturatesAtClientTransportCeiling() {
        let document = FileDiffDocument(
            hunks: [],
            truncated: true,
            isBinary: false,
            loadedLineCount: 6_000,
            totalLineCount: 2_000_000
        )

        #expect(FileDiffContinuation(lineBudget: 6_000, document: document).nextLineBudget == 24_000)
        #expect(FileDiffContinuation(lineBudget: 24_000, document: document).nextLineBudget == 96_000)
        #expect(FileDiffContinuation(lineBudget: 384_000, document: document).lineBudget == 96_000)
        #expect(FileDiffContinuation(lineBudget: 384_000, document: document).nextLineBudget == 96_000)
        #expect(FileDiffContinuation(lineBudget: Int.max, document: document).nextLineBudget == 96_000)
    }

    @Test func diffContinuationProvidesProgressAndLegacyFooterInputs() {
        let known = FileDiffDocument(
            hunks: [],
            truncated: true,
            isBinary: false,
            loadedLineCount: 6_000,
            totalLineCount: 12_004
        )
        let legacy = FileDiffDocument(
            hunks: [],
            truncated: true,
            isBinary: false,
            loadedLineCount: 5_998
        )
        let complete = FileDiffDocument(
            hunks: [],
            truncated: false,
            isBinary: false,
            loadedLineCount: 12_004,
            totalLineCount: 12_004
        )

        let knownContinuation = FileDiffContinuation(lineBudget: 6_000, document: known)
        #expect(knownContinuation.shownLineCount == 6_000)
        #expect(knownContinuation.totalLineCount == 12_004)
        #expect(knownContinuation.canShowMore)
        #expect(knownContinuation.shouldShowFooter)

        let legacyContinuation = FileDiffContinuation(lineBudget: 6_000, document: legacy)
        #expect(legacyContinuation.shownLineCount == 5_998)
        #expect(legacyContinuation.totalLineCount == nil)
        #expect(legacyContinuation.canShowMore)
        #expect(legacyContinuation.shouldShowFooter)

        let completeContinuation = FileDiffContinuation(lineBudget: 24_000, document: complete)
        #expect(completeContinuation.shownLineCount == completeContinuation.totalLineCount)
        #expect(!completeContinuation.shouldShowFooter)
    }

    @Test func diffContinuationStopsAfterLargerBudgetFailsToGrowRawWindow() {
        let initial = FileDiffDocument(
            hunks: [],
            truncated: true,
            isBinary: false,
            loadedLineCount: 70_000,
            totalLineCount: 500_000
        )
        let sameWindow = FileDiffDocument(
            hunks: [],
            truncated: true,
            isBinary: false,
            loadedLineCount: 70_000,
            totalLineCount: 500_000
        )
        let grownWindow = FileDiffDocument(
            hunks: [],
            truncated: true,
            isBinary: false,
            loadedLineCount: 70_001,
            totalLineCount: 500_000
        )
        let continuation = FileDiffContinuation(lineBudget: 96_000, document: initial)

        #expect(continuation.reachedTransportCeiling(
            afterLoading: sameWindow,
            requestedLineBudget: 384_000
        ))
        #expect(!continuation.reachedTransportCeiling(
            afterLoading: sameWindow,
            requestedLineBudget: 96_000
        ))
        #expect(!continuation.reachedTransportCeiling(
            afterLoading: grownWindow,
            requestedLineBudget: 384_000
        ))

        let exhausted = FileDiffContinuation(
            lineBudget: 384_000,
            document: sameWindow,
            reachedTransportCeiling: true
        )
        #expect(exhausted.shouldShowFooter)
        #expect(!exhausted.canShowMore)
    }

    @Test func continuationWithoutTotalStopsAtClientOrNoGrowthCeiling() {
        let unknownTotal = FileDiffDocument(
            hunks: [],
            truncated: true,
            isBinary: false,
            loadedLineCount: 24_000
        )

        #expect(FileDiffContinuation(
            lineBudget: 24_000,
            document: unknownTotal
        ).canShowMore)
        #expect(!FileDiffContinuation(
            lineBudget: 96_000,
            document: unknownTotal
        ).canShowMore)
        #expect(!FileDiffContinuation(
            lineBudget: 24_000,
            document: unknownTotal,
            reachedTransportCeiling: true
        ).canShowMore)
    }

    @Test func presentationCacheEvictsLeastRecentlyUsedBeyondSevenPages() async {
        let presentation = await FileDiffPresentation.prepareOffMain(
            document: FileDiffDocument(hunks: [], truncated: false, isBinary: false),
            fileKind: .modified
        )
        var cache = FileDiffPresentationCache()
        for index in 0..<7 {
            cache.insert(presentation, forPath: "file-\(index)")
        }
        _ = cache.presentation(forPath: "file-0")
        cache.insert(presentation, forPath: "file-7")

        #expect(cache.presentations.count == 7)
        #expect(cache.presentations["file-0"] != nil)
        #expect(cache.presentations["file-1"] == nil)
        #expect(cache.presentations["file-7"] != nil)
    }

    @Test func diffPagerMountsOnlySelectedPageAndImmediateNeighbors() {
        let policy = DiffPagerMountPolicy()

        #expect(policy.mountedIndices(selectedIndex: 0, pageCount: 20) == [0, 1])
        #expect(policy.mountedIndices(selectedIndex: 10, pageCount: 20) == [9, 10, 11])
        #expect(policy.mountedIndices(selectedIndex: 19, pageCount: 20) == [18, 19])
        #expect(policy.shouldMount(pageIndex: 11, selectedIndex: 10))
        #expect(!policy.shouldMount(pageIndex: 12, selectedIndex: 10))
    }

    @Test func loadedListStateSurfacesOnlyTruncatedSnapshots() {
        #expect(WorkspaceChangesListState.loaded(truncated: true).showsTruncatedFilesFooter)
        #expect(!WorkspaceChangesListState.loaded(truncated: false).showsTruncatedFilesFooter)
        #expect(!WorkspaceChangesListState.loading.showsTruncatedFilesFooter)
    }

    @Test func expansionRevisionPolicyFailsClosedForMissingOrMismatchedFingerprints() {
        let policy = DiffExpansionRevisionPolicy()

        #expect(policy.decision(
            diffContentFingerprint: "stat:10:1:2:3:4",
            fetchedContentFingerprints: ["stat:10:1:2:3:4", "stat:10:1:2:3:4"]
        ) == .accept)
        #expect(policy.decision(
            diffContentFingerprint: "stat:10:1:2:3:4",
            fetchedContentFingerprints: ["stat:10:1:2:4:4"]
        ) == .reloadDiff)
        #expect(policy.decision(
            diffContentFingerprint: "stat:10:1",
            fetchedContentFingerprints: ["stat:10:1"]
        ) == .reloadDiff)
        #expect(policy.decision(
            diffContentFingerprint: nil,
            fetchedContentFingerprints: [nil, nil]
        ) == .reloadDiff)
        #expect(policy.decision(
            diffContentFingerprint: nil,
            fetchedContentFingerprints: ["stat:10:1:2:3:4"]
        ) == .reloadDiff)
        #expect(policy.decision(
            diffContentFingerprint: "10:1:2",
            fetchedContentFingerprints: []
        ) == .reloadDiff)
        #expect(policy.decision(
            diffContentFingerprint: "10:1:2",
            fetchedContentFingerprints: ["10:1:2", nil]
        ) == .reloadDiff)
        #expect(policy.decision(
            diffContentFingerprint: "",
            fetchedContentFingerprints: [nil]
        ) == .reloadDiff)
    }
}
