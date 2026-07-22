import Testing

@testable import CmuxMobileChanges

@Suite struct DiffRowSnapshotTests {
    @Test func flattensHunksIntoOrderedRowsWithHeaderGaps() {
        let diff = """
        diff --git a/Sources/Foo.swift b/Sources/Foo.swift
        index 1111111..2222222 100644
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -1,3 +1,4 @@
         import Foundation
        -let old = 1
        +let value = 2
        +let extra = 3
         print(value)
        @@ -10,2 +11,2 @@ final class Widget {
        -    func oldName() {}
        +    func newName() {}
         }
        """
        let document = UnifiedDiffParser().parse(diff)

        let rows = DiffRowSnapshot.rows(for: document)

        // One row per document line (headers included), in wire order.
        #expect(rows.count == document.lines.count)
        #expect(rows.map(\.id) == Array(0..<rows.count))
        #expect(rows[0].line == document.hunks[0].header)
        #expect(rows[0].leadingHunkGap == false)
        let secondHeaderIndex = document.hunks[0].lines.count + 1
        #expect(rows[secondHeaderIndex].line == document.hunks[1].header)
        #expect(rows[secondHeaderIndex].leadingHunkGap == true)
        // Only later hunk headers carry the gap.
        #expect(rows.filter(\.leadingHunkGap).count == document.hunks.count - 1)
        // Every row carries its own hunk's copy text.
        #expect(rows[1].hunkCopyText == document.hunks[0].copyText)
        #expect(rows.last?.hunkCopyText == document.hunks[1].copyText)
    }
}
