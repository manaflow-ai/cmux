import Testing

@testable import CmuxMobileChanges

@Suite struct UnifiedDiffParserTests {
    private let parser = UnifiedDiffParser()

    @Test func parsesModifiedFileWithMultipleHunksAndLineNumbers() throws {
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

        let document = parser.parse(diff)
        #expect(document.hunks.count == 2)
        #expect(document.lines.count == 10)
        let first = try #require(document.hunks.first)
        #expect(first.oldStart == 1)
        #expect(first.oldCount == 3)
        #expect(first.newStart == 1)
        #expect(first.newCount == 4)
        #expect(first.sectionContext == nil)
        #expect(first.lines.map(\.oldNumber) == [1, 2, nil, nil, 3])
        #expect(first.lines.map(\.newNumber) == [1, nil, 2, 3, 4])
        let second = try #require(document.hunks.last)
        #expect(second.sectionContext == "final class Widget {")
        #expect(second.lines.map(\.oldNumber) == [10, nil, 11])
        #expect(second.lines.map(\.newNumber) == [nil, 11, 12])
    }

    @Test func parsesNewFileCoordinates() throws {
        let diff = """
        diff --git a/New.swift b/New.swift
        new file mode 100644
        --- /dev/null
        +++ b/New.swift
        @@ -0,0 +1,2 @@
        +first
        +second
        """

        let hunk = try #require(parser.parse(diff).hunks.first)
        #expect(hunk.oldStart == 0)
        #expect(hunk.oldCount == 0)
        #expect(hunk.newStart == 1)
        #expect(hunk.newCount == 2)
        #expect(hunk.lines.map(\.oldNumber) == [nil, nil])
        #expect(hunk.lines.map(\.newNumber) == [1, 2])
        #expect(hunk.lines.allSatisfy { $0.kind == .addition })
    }

    @Test func parsesDeletedFileCoordinates() throws {
        let diff = """
        deleted file mode 100644
        --- a/Old.swift
        +++ /dev/null
        @@ -4,2 +0,0 @@
        -first
        -second
        """

        let hunk = try #require(parser.parse(diff).hunks.first)
        #expect(hunk.oldStart == 4)
        #expect(hunk.oldCount == 2)
        #expect(hunk.newStart == 0)
        #expect(hunk.newCount == 0)
        #expect(hunk.lines.map(\.oldNumber) == [4, 5])
        #expect(hunk.lines.map(\.newNumber) == [nil, nil])
        #expect(hunk.lines.allSatisfy { $0.kind == .removal })
    }

    @Test func renameOnlyDiffHasNoHunks() {
        let diff = """
        diff --git a/Old.swift b/New.swift
        similarity index 100%
        rename from Old.swift
        rename to New.swift
        """

        let document = parser.parse(diff)
        #expect(document.hunks.isEmpty)
        #expect(document.lines.isEmpty)
    }

    @Test func emitsNoTrailingNewlineMarkersAfterAffectedLinesWithoutAdvancingNumbers() throws {
        let diff = """
        @@ -8 +8 @@
        -let value = 1
        \\ No newline at end of file
        +let value = 2
        \\ No newline at end of file
        """

        let hunk = try #require(parser.parse(diff).hunks.first)
        #expect(hunk.lines.count == 4)
        #expect(hunk.lines[0].oldNumber == 8)
        #expect(hunk.lines[0].newNumber == nil)
        #expect(hunk.lines[1].kind == .noNewlineMarker)
        #expect(hunk.lines[1].oldNumber == nil)
        #expect(hunk.lines[1].newNumber == nil)
        #expect(hunk.lines[2].oldNumber == nil)
        #expect(hunk.lines[2].newNumber == 8)
        #expect(hunk.lines[3].kind == .noNewlineMarker)
        #expect(!hunk.lines[0].emphasisRanges.isEmpty)
        #expect(!hunk.lines[2].emphasisRanges.isEmpty)
        #expect(hunk.copyText == "@@ -8 +8 @@\n-let value = 1\n+let value = 2")
    }

    @Test func parsesHunkHeaderFunctionContext() throws {
        let hunk = try #require(parser.parse("""
        @@ -20,2 +20,3 @@ func render(value: Int) -> String {
         let prefix = "value"
        +return prefix
         }
        """).hunks.first)

        #expect(hunk.sectionContext == "func render(value: Int) -> String {")
        #expect(hunk.header.kind == .hunkHeader)
        #expect(hunk.header.text.hasPrefix("@@ -20,2 +20,3 @@"))
    }

    @Test func emptyBinaryAndTruncatedDocumentsPreserveFlags() {
        let empty = parser.parse("")
        #expect(empty.lines.isEmpty)
        #expect(!empty.isBinary)
        #expect(!empty.truncated)

        let binary = parser.parse("Binary files differ", isBinary: true)
        #expect(binary.lines.isEmpty)
        #expect(binary.isBinary)

        let truncated = parser.parse("@@ -1 +1 @@\n-old\n+new", truncated: true)
        #expect(truncated.truncated)
        #expect(truncated.hunks.count == 1)
    }

    @Test func preservesCarriageReturnInCRLFFileContent() throws {
        let diff = "@@ -1 +1 @@\n-old\r\n+new\r\n"
        let hunk = try #require(parser.parse(diff).hunks.first)
        #expect(hunk.lines[0].text == "old\r")
        #expect(hunk.lines[1].text == "new\r")
    }

    @Test func asyncWorkerParsesAndAppliesIntraLineEmphasis() async throws {
        let document = await parser.parseOffMain("""
        @@ -1 +1 @@
        -let value = oldName
        +let value = newName
        """)
        let hunk = try #require(document.hunks.first)

        #expect(!hunk.lines[0].emphasisRanges.isEmpty)
        #expect(!hunk.lines[1].emphasisRanges.isEmpty)
    }
}
