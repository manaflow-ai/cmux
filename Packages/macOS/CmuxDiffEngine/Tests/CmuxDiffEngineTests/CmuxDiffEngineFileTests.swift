import CmuxDiffEngine
import Foundation
import Testing

@Suite
struct CmuxDiffEngineFileTests {
    @Test
    func parsesNumberedHunksNoNewlineMarkersAndPagesRows() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        try repo.write("one\ntwo\nthree\nfour\n", path: "page.txt")
        _ = try repo.commitAll()
        try repo.write("one\nTWO\nthree\nfour\nfive", path: "page.txt")
        let engine = CmuxDiffEngine(rowLimit: 2)

        let first = try await engine.fileHunks(
            repositoryPath: repo.root.path,
            path: "page.txt",
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        )
        #expect(first.hunks.flatMap(\.rows).count == 2)
        #expect(first.nextCursor == 2)
        let second = try await engine.fileHunks(
            repositoryPath: repo.root.path,
            path: "page.txt",
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false,
            cursor: first.nextCursor
        )
        #expect(second.hunks.flatMap(\.rows).count == 2)
        #expect(second.nextCursor == 4)

        var cursor: Int? = 0
        var rows: [DiffRow] = []
        repeat {
            let page = try await engine.fileHunks(
                repositoryPath: repo.root.path,
                path: "page.txt",
                baseSpec: DiffBaseSpec(kind: .workingTree),
                ignoreWhitespace: false,
                cursor: cursor
            )
            rows.append(contentsOf: page.hunks.flatMap(\.rows))
            cursor = page.nextCursor
        } while cursor != nil
        #expect(rows.contains(DiffRow(kind: .del, oldNo: 2, newNo: nil, text: "two")))
        #expect(rows.contains(DiffRow(kind: .add, oldNo: nil, newNo: 2, text: "TWO")))
        #expect(rows.contains(DiffRow(kind: .add, oldNo: nil, newNo: 5, text: "five")))
        #expect(rows.last?.kind == .noNewline)
    }

    @Test
    func gatesLargeLineCountUntilForced() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        let content = (1...3_001).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try repo.write(content, path: "large.txt")
        let engine = CmuxDiffEngine(rowLimit: 2_000)
        let summary = try await engine.summary(
            repositoryPath: repo.root.path,
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        )
        #expect(summary.files.first?.isLarge == true)

        let gated = try await engine.fileHunks(
            repositoryPath: repo.root.path,
            path: "large.txt",
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        )
        #expect(gated.tooLarge)
        #expect(gated.hunks.isEmpty)
        let forced = try await engine.fileHunks(
            repositoryPath: repo.root.path,
            path: "large.txt",
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false,
            force: true
        )
        #expect(!forced.tooLarge)
        #expect(forced.hunks.flatMap(\.rows).count == 2_000)
        #expect(forced.nextCursor == 2_000)
    }

    @Test
    func detectsPatchByteLimitAndBinaryNumstat() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        try repo.write("seed\n", path: "huge.txt")
        try repo.write(Data([0, 1, 2, 3]), path: "binary.dat")
        _ = try repo.commitAll()
        try repo.write(String(repeating: "x", count: 1_048_700) + "\n", path: "huge.txt")
        try repo.write(Data([0, 1, 4, 5]), path: "binary.dat")

        let summary = try await CmuxDiffEngine().summary(
            repositoryPath: repo.root.path,
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        )
        #expect(summary.files.first(where: { $0.path == "huge.txt" })?.isLarge == true)
        let binary = try #require(summary.files.first(where: { $0.path == "binary.dat" }))
        #expect(binary.isBinary)
        let page = try await CmuxDiffEngine().fileHunks(
            repositoryPath: repo.root.path,
            path: "binary.dat",
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        )
        #expect(page.isBinary)
        #expect(page.hunks.isEmpty)
    }

    @Test
    func readsWorkingAndDeletedFileContext() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        try repo.write("old one\nold two\nold three\n", path: "deleted.txt")
        try repo.write("one\ntwo\nthree\nfour\n", path: "working.txt")
        _ = try repo.commitAll()
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("deleted.txt"))
        try repo.write("one\nchanged\nthree\nfour\n", path: "working.txt")

        let engine = CmuxDiffEngine()
        let working = try await engine.contextRows(
            repositoryPath: repo.root.path,
            path: "working.txt",
            startLine: 2,
            endLine: 3
        )
        let deleted = try await engine.contextRows(
            repositoryPath: repo.root.path,
            path: "deleted.txt",
            startLine: 1,
            endLine: 2
        )
        #expect(working == ["changed", "three"])
        #expect(deleted == ["old one", "old two"])
    }

    @Test
    func stablePatchDigestChangesWithContent() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        try repo.write("base\n", path: "digest.txt")
        _ = try repo.commitAll()
        try repo.write("base\nfirst\n", path: "digest.txt")
        let engine = CmuxDiffEngine()
        let first = try await engine.summary(
            repositoryPath: repo.root.path,
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        ).files[0].patchDigest
        let repeatDigest = try await engine.summary(
            repositoryPath: repo.root.path,
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        ).files[0].patchDigest
        try repo.write("base\nsecond\n", path: "digest.txt")
        let changed = try await engine.summary(
            repositoryPath: repo.root.path,
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        ).files[0].patchDigest
        #expect(first == repeatDigest)
        #expect(first != changed)
    }
}
