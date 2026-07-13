import Testing

@testable import CmuxDiffModel

@Suite struct UnifiedDiffParserTests {
    @Test func cancelledParseAvoidsProducingRows() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return UnifiedDiffParser().parse(
                "@@ -1,2 +1,2 @@\n-old\n+new\n context\n",
                isTruncated: true
            )
        }

        let result = await task.value

        #expect(result.hunks.isEmpty)
        #expect(result.isTruncated)
    }

    private let parser = UnifiedDiffParser()

    @Test func parsesMultiHunkFile() {
        let diff = """
        diff --git a/file.swift b/file.swift
        index 1111111..2222222 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,4 @@
         one
        -two
        +two changed
        +three
         four
        @@ -10,2 +11,2 @@
         ten
        -old
        +new
        """

        let result = parser.parse(diff)

        #expect(result.hunks.count == 2)
        #expect(result.hunks[0].oldStart == 1)
        #expect(result.hunks[0].newCount == 4)
        #expect(result.hunks[0].lines.map(\.kind) == [.context, .deletion, .addition, .addition, .context])
        #expect(result.hunks[0].lines[1].oldLine == 2)
        #expect(result.hunks[0].lines[2].newLine == 2)
        #expect(result.hunks[1].oldStart == 10)
    }

    @Test func ignoresRenameHeadersAndParsesHunk() {
        let diff = """
        diff --git a/Old.swift b/New.swift
        similarity index 90%
        rename from Old.swift
        rename to New.swift
        --- a/Old.swift
        +++ b/New.swift
        @@ -2 +2 @@
        -oldName()
        +newName()
        """

        let result = parser.parse(diff)

        #expect(result.hunks.count == 1)
        #expect(result.hunks[0].oldCount == 1)
        #expect(result.hunks[0].newCount == 1)
        #expect(result.hunks[0].lines.map(\.text) == ["oldName()", "newName()"])
    }

    @Test func parsesUntrackedNoIndexDiff() {
        let diff = """
        diff --git a/dev/null b/new.txt
        new file mode 100644
        index 0000000..aaaaaaa
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +first
        +second
        """

        let result = parser.parse(diff)

        #expect(result.hunks.count == 1)
        #expect(result.hunks[0].oldStart == 0)
        #expect(result.hunks[0].oldCount == 0)
        #expect(result.hunks[0].lines.allSatisfy { $0.kind == .addition })
        #expect(result.hunks[0].lines.map(\.newLine) == [1, 2])
    }

    @Test func fileBoundaryDoesNotBecomeNumberedHunkContext() {
        let diff = """
        diff --git a/Old.swift b/Old.swift
        --- a/Old.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -old
        diff --git a/New.swift b/New.swift
        --- /dev/null
        +++ b/New.swift
        @@ -0,0 +1 @@
        +new
        """

        let result = parser.parse(diff)

        #expect(result.hunks.count == 2)
        #expect(result.hunks[0].lines.map(\.text) == ["old"])
        #expect(result.hunks[1].lines.map(\.text) == ["new"])
    }

    @Test func binaryDiffProducesNoHunks() {
        let diff = """
        diff --git a/image.png b/image.png
        index 1111111..2222222 100644
        Binary files a/image.png and b/image.png differ
        """

        #expect(parser.parse(diff).hunks.isEmpty)
    }

    @Test func emptyDiffProducesNoHunks() {
        #expect(parser.parse("").hunks.isEmpty)
    }

    @Test func trailingNewlineDoesNotAppendPhantomContextLine() {
        let diff = "@@ -1 +1 @@\n-old\n+new\n"

        let result = parser.parse(diff)

        #expect(result.hunks.count == 1)
        #expect(result.hunks[0].lines.count == 2)
        #expect(result.hunks[0].lines.map(\.kind) == [.deletion, .addition])
        #expect(result.hunks[0].lines[1].newLine == 1)
    }

    @Test func parsesCRLFTerminatedRowsSeparately() throws {
        let result = parser.parse("@@ -1 +1 @@\n-old\r\n+new\r\n")
        let hunk = try #require(result.hunks.first)

        #expect(hunk.lines.map(\.kind) == [.deletion, .addition])
        #expect(hunk.lines.map(\.text) == ["old", "new"])
        #expect(hunk.lines.map(\.oldLine) == [1, nil])
        #expect(hunk.lines.map(\.newLine) == [nil, 1])
    }

    @Test func preservesTruncationFlag() {
        let result = parser.parse("@@ -1 +1 @@\n-old\n+new", isTruncated: true)

        #expect(result.isTruncated)
        #expect(result.hunks.count == 1)
    }

    @Test func capsRowsPerHunkAndMarksResultTruncated() {
        let additions = (0..<2_100).map { "+line-\($0)" }.joined(separator: "\n")
        let result = parser.parse("@@ -0,0 +1,2100 @@\n\(additions)")

        #expect(result.hunks.count == 1)
        #expect(result.hunks[0].lines.count == 2_000)
        #expect(result.isTruncated)
    }

    @Test func capsIndividualRowsAndMarksResultTruncated() throws {
        let oversizedText = String(repeating: "é", count: 100_000)
        let result = parser.parse("@@ -0,0 +1 @@\n+\(oversizedText)")
        let line = try #require(result.hunks.first?.lines.first)

        #expect(line.text.utf8.count <= 8 * 1024)
        #expect(line.text.utf8.count.isMultiple(of: 2))
        #expect(result.isTruncated)
    }

    @Test func capsTotalRowsAcrossHunksAndMarksResultTruncated() {
        let hunks = (0..<11).map { hunk in
            let start = hunk * 2_000 + 1
            let additions = (0..<2_000).map { "+h\(hunk)-line-\($0)" }.joined(separator: "\n")
            return "@@ -0,0 +\(start),2000 @@\n\(additions)"
        }.joined(separator: "\n")

        let result = parser.parse(hunks)

        #expect(result.hunks.count == 10)
        #expect(result.hunks.flatMap(\.lines).count == 20_000)
        #expect(result.isTruncated)
    }
}
