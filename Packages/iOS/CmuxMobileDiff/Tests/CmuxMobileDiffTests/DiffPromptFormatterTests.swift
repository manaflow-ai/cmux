import CmuxMobileRPC
import Testing
@testable import CmuxMobileDiff

@Suite struct DiffPromptFormatterTests {
    private let formatter = DiffPromptFormatter()

    @Test func formatsNewSideLineWithExactPathHunkAndFence() {
        let context = DiffNoteContext(
            id: "new-line",
            path: "Sources/Feature/App.swift",
            lineReference: DiffNoteLineReference(number: 24, isOld: false),
            hunkReference: "@@ -20,3 +20,4 @@",
            excerpt: "+let enabled = true"
        )

        #expect(formatter.prompt(context: context, note: "Please add coverage.") == """
        Regarding `Sources/Feature/App.swift` line 24, hunk @@ -20,3 +20,4 @@:
        ```diff
        +let enabled = true
        ```
        Please add coverage.
        """)
    }

    @Test func labelsDeletionAsOldAndKeepsAsciiMinusMarker() {
        let context = DiffNoteContext(
            id: "old-line",
            path: "README.md",
            lineReference: DiffNoteLineReference(number: 7, isOld: true),
            hunkReference: "@@ -7,2 +7,0 @@",
            excerpt: "-obsolete guidance"
        )

        #expect(formatter.prompt(context: context, note: "Why was this removed?") == """
        Regarding `README.md` line 7 (old), hunk @@ -7,2 +7,0 @@:
        ```diff
        -obsolete guidance
        ```
        Why was this removed?
        """)
    }

    @Test func wholeHunkPreservesEveryPrefixedLineInsideOneFence() {
        let context = DiffNoteContext(
            id: "hunk",
            path: "Sources/Counter.swift",
            lineReference: DiffNoteLineReference(number: 11, isOld: false),
            hunkReference: "@@ -10,3 +10,3 @@",
            excerpt: " context\n-oldValue\n+newValue"
        )

        #expect(formatter.prompt(context: context, note: "Review this change.") == """
        Regarding `Sources/Counter.swift` line 11, hunk @@ -10,3 +10,3 @@:
        ```diff
         context
        -oldValue
        +newValue
        ```
        Review this change.
        """)
    }

    @Test func contextBuilderFormatsWholeHunkFromRenderedRows() throws {
        let file = MobileChangesFile(
            path: "Sources/Value.swift",
            oldPath: nil,
            status: .modified,
            additions: 1,
            deletions: 1,
            isBinary: false,
            isLarge: false,
            patchDigest: "digest"
        )
        let rows = DiffRowBuilder().rows(
            file: file,
            hunks: [MobileChangesHunk(
                oldStart: 5,
                oldLines: 1,
                newStart: 5,
                newLines: 1,
                sectionHeading: "updateValue()",
                rows: [
                    MobileChangesDiffRow(kind: .del, oldNo: 5, newNo: nil, text: "oldValue"),
                    MobileChangesDiffRow(kind: .add, oldNo: nil, newNo: 5, text: "newValue"),
                ]
            )],
            includeEOFGap: false
        )
        let snapshot = DiffFileSnapshot(
            file: file,
            rows: rows,
            isCollapsed: false,
            isViewed: false,
            isLoading: false
        )
        let header = try #require(rows.first { $0.kind == .hunkHeader })
        let context = try #require(DiffNoteContextBuilder().context(
            file: snapshot,
            presentedRow: header,
            scope: .hunk
        ))

        #expect(formatter.prompt(context: context, note: "Check this.") == """
        Regarding `Sources/Value.swift` line 5, hunk @@ -5,1 +5,1 @@:
        ```diff
        -oldValue
        +newValue
        ```
        Check this.
        """)
    }
}
