import CmuxChangesEngine
import Testing

@Suite
struct ChangesEngineFileDiffTests {
    @Test
    func pagingCursorRoundTripsEveryRow() async throws {
        let fixture = try await GitFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.git([
            "-c", "user.email=fixture@example.com", "-c", "user.name=Fixture",
            "commit", "--allow-empty", "-qm", "empty",
        ])
        try fixture.write("paged.txt", (1...4_500).map { "row \($0)" }.joined(separator: "\n") + "\n")
        _ = try await fixture.git(["add", "paged.txt"])

        let engine = ChangesEngine()
        let first = try await engine.fileDiff(
            repoRoot: fixture.root.path,
            base: .workingTree,
            path: "paged.txt",
            oldPath: nil,
            cursor: nil,
            ignoreWhitespace: false
        )
        let firstRows = first.hunks.flatMap(\.rows)
        #expect(firstRows.count == 4_000)
        #expect(first.nextCursor == "4000")
        #expect(first.tooLarge)

        let second = try await engine.fileDiff(
            repoRoot: fixture.root.path,
            base: .workingTree,
            path: "paged.txt",
            oldPath: nil,
            cursor: first.nextCursor,
            ignoreWhitespace: false
        )
        let secondRows = second.hunks.flatMap(\.rows)
        #expect(secondRows.count == 500)
        #expect(second.nextCursor == nil)
        #expect(firstRows.first?.newNo == 1)
        #expect(secondRows.first?.newNo == 4_001)
        #expect(secondRows.last?.newNo == 4_500)
    }

    @Test
    func contextLinesReadWorkingTreeAndHeadForDeletion() async throws {
        let fixture = try await GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("tracked.txt", "one\ntwo\nthree\n")
        try fixture.write("deleted.txt", "alpha\nbeta\ngamma\n")
        try await fixture.commitAll("context")
        try fixture.write("tracked.txt", "one\nTWO\nthree\nfour\n")
        try fixture.remove("deleted.txt")

        let engine = ChangesEngine()
        let tracked = try await engine.contextLines(
            repoRoot: fixture.root.path,
            base: .workingTree,
            path: "tracked.txt",
            startLine: 2,
            endLine: 3
        )
        let deleted = try await engine.contextLines(
            repoRoot: fixture.root.path,
            base: .workingTree,
            path: "deleted.txt",
            startLine: 1,
            endLine: 2
        )
        #expect(tracked == ["TWO", "three"])
        #expect(deleted == ["alpha", "beta"])
    }

    @Test
    func hunkRowsHaveHandComputedLineNumbers() async throws {
        let fixture = try await GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("numbers.txt", "one\ntwo\nthree\nfour\nfive\nsix\n")
        try await fixture.commitAll("numbers")
        try fixture.write("numbers.txt", "one\ntwo\nTHREE\nfour\nsix\nseven\n")

        let diff = try await ChangesEngine().fileDiff(
            repoRoot: fixture.root.path,
            base: .workingTree,
            path: "numbers.txt",
            oldPath: nil,
            cursor: nil,
            ignoreWhitespace: false
        )
        let rows = try #require(diff.hunks.first).rows
        let actual = rows.map { ($0.kind, $0.oldNo, $0.newNo, $0.text) }
        #expect(actual.count == 8)
        #expect(actual[0] == (.context, 1, 1, "one"))
        #expect(actual[1] == (.context, 2, 2, "two"))
        #expect(actual[2] == (.del, 3, nil, "three"))
        #expect(actual[3] == (.add, nil, 3, "THREE"))
        #expect(actual[4] == (.context, 4, 4, "four"))
        #expect(actual[5] == (.del, 5, nil, "five"))
        #expect(actual[6] == (.context, 6, 5, "six"))
        #expect(actual[7] == (.add, nil, 6, "seven"))
    }

    @Test
    func renamedFileUsesOldAndNewLiteralPathspecs() async throws {
        let fixture = try await GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("old name.txt", (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try await fixture.commitAll("rename")
        _ = try await fixture.git(["mv", "old name.txt", "new name.txt"])
        try fixture.write("new name.txt", (1...19).map { "line \($0)" }.joined(separator: "\n") + "\nchanged\n")
        _ = try await fixture.git(["add", "new name.txt"])

        let diff = try await ChangesEngine().fileDiff(
            repoRoot: fixture.root.path,
            base: .workingTree,
            path: "new name.txt",
            oldPath: "old name.txt",
            cursor: nil,
            ignoreWhitespace: false
        )
        #expect(!diff.hunks.isEmpty)
        #expect(diff.hunks.flatMap(\.rows).contains { $0.text == "changed" })
    }
}
