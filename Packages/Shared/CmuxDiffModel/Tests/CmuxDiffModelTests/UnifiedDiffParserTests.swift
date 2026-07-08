import Testing

@testable import CmuxDiffModel

@Suite struct UnifiedDiffParserTests {
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

    @Test func preservesTruncationFlag() {
        let result = parser.parse("@@ -1 +1 @@\n-old\n+new", isTruncated: true)

        #expect(result.isTruncated)
        #expect(result.hunks.count == 1)
    }
}
