import CmuxDiffEngine
import Foundation
import Testing

@Suite
struct CmuxDiffEngineSummaryTests {
    @Test
    func summarizesStagedUnstagedAndUntrackedFilesWithNulSafePaths() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        try repo.write("one\n", path: "tracked.txt")
        _ = try repo.commitAll()

        try repo.write("one\ntwo\n", path: "tracked.txt")
        try repo.write("first\nsecond\n", path: "added name.txt")
        try repo.git(["add", "added name.txt"])
        try repo.write("uno\ndos", path: "untracked ü.txt")
        try FileManager.default.createSymbolicLink(
            at: repo.root.appendingPathComponent("ignored-link"),
            withDestinationURL: repo.root.appendingPathComponent("untracked ü.txt")
        )

        let summary = try await CmuxDiffEngine().summary(
            repositoryPath: repo.root.path,
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        )

        #expect(summary.totals == DiffTotals(files: 3, additions: 5, deletions: 0))
        #expect(summary.files.first(where: { $0.path == "tracked.txt" })?.status == .modified)
        #expect(summary.files.first(where: { $0.path == "added name.txt" })?.status == .added)
        let untracked = try #require(summary.files.first(where: { $0.path == "untracked ü.txt" }))
        #expect(untracked.status == .untracked)
        #expect(untracked.additions == 2)
        #expect(untracked.patchDigest.count == 64)
        #expect(!summary.files.contains(where: { $0.path == "ignored-link" }))
    }

    @Test
    func detectsRenameAndCopyWithOldPaths() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        try repo.write("alpha\nbeta\ngamma\ndelta\n", path: "original.txt")
        _ = try repo.commitAll()

        try repo.git(["mv", "original.txt", "renamed.txt"])
        try repo.write("alpha\nbeta\ngamma\ndelta\nchanged\n", path: "renamed.txt")
        try repo.write("alpha\nbeta\ngamma\ndelta\n", path: "copy.txt")
        try repo.git(["add", "copy.txt"])

        let summary = try await CmuxDiffEngine().summary(
            repositoryPath: repo.root.path,
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        )
        let renamed = try #require(summary.files.first(where: { $0.status == .renamed }))
        let copied = try #require(summary.files.first(where: { $0.status == .copied }))
        #expect(renamed.oldPath == "original.txt")
        #expect(copied.oldPath == "original.txt")

        let page = try await CmuxDiffEngine().fileHunks(
            repositoryPath: repo.root.path,
            path: renamed.path,
            oldPath: renamed.oldPath,
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        )
        let rows = page.hunks.flatMap(\.rows)
        let containsChangedAddition = rows.contains { row in
            row.kind == .add && row.text == "changed"
        }
        #expect(containsChangedAddition)
    }

    @Test
    func ignoresWhitespaceOnlyChangesWhenRequested() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        try repo.write("alpha beta\n", path: "space.txt")
        _ = try repo.commitAll()
        try repo.write("alpha     beta\n", path: "space.txt")

        let included = try await CmuxDiffEngine().summary(
            repositoryPath: repo.root.path,
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        )
        let ignored = try await CmuxDiffEngine().summary(
            repositoryPath: repo.root.path,
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: true
        )
        #expect(included.totals.files == 1)
        #expect(ignored.totals.files == 0)
    }

    @Test
    func usesEmptyTreeForUnbornHead() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        try repo.write("first\nsecond\n", path: "birth.txt")
        try repo.git(["add", "birth.txt"])

        let emptyTree = try repo.gitOutput(["hash-object", "-t", "tree", "/dev/null"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = try await CmuxDiffEngine().summary(
            repositoryPath: repo.root.path,
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        )
        #expect(summary.baseInfo.resolvedRef == emptyTree)
        #expect(summary.files.first?.status == .added)
        #expect(summary.totals.additions == 2)
    }

    @Test
    func resolvesBranchMergeBase() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        try repo.write("base\n", path: "story.txt")
        let base = try repo.commitAll("base")
        try repo.git(["switch", "-q", "-c", "feature"])
        try repo.write("base\nfeature\n", path: "story.txt")
        _ = try repo.commitAll("feature")
        try repo.write("base\nfeature\nworking\n", path: "story.txt")

        let summary = try await CmuxDiffEngine().summary(
            repositoryPath: repo.root.path,
            baseSpec: DiffBaseSpec(kind: .branchBase),
            ignoreWhitespace: false
        )
        #expect(summary.baseInfo.resolvedRef == base)
        #expect(summary.totals.additions == 2)
    }

    @Test
    func comparesAgainstResolvedLastTurnObject() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        try repo.write("before\n", path: "turn.txt")
        let baseline = try repo.commitAll("turn baseline")
        try repo.write("before\nafter\n", path: "turn.txt")

        let summary = try await CmuxDiffEngine().summary(
            repositoryPath: repo.root.path,
            baseSpec: DiffBaseSpec(kind: .lastTurn, value: baseline),
            ignoreWhitespace: false
        )
        #expect(summary.baseInfo.kind == .lastTurn)
        #expect(summary.baseInfo.resolvedRef == baseline)
        #expect(summary.totals.additions == 1)
    }

    @Test
    func hardensAndBatchesGitCommandsWithoutPerUntrackedSpawns() async throws {
        let repo = try FixtureRepository()
        defer { repo.remove() }
        try repo.write("tracked\n", path: "tracked.txt")
        _ = try repo.commitAll()
        try repo.write("tracked\nchanged\n", path: "tracked.txt")
        try repo.write("one\n", path: "untracked-one.txt")
        try repo.write("two\n", path: "untracked-two.txt")
        let runner = RecordingCommandRunner()

        _ = try await CmuxDiffEngine(commandRunner: runner).summary(
            repositoryPath: repo.root.path,
            baseSpec: DiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        )
        let calls = await runner.arguments()
        #expect(calls.allSatisfy { $0.prefix(2) == ["-c", "core.quotepath=false"] })
        let diffCalls = calls.filter { $0.contains("diff") }
        #expect(diffCalls.count == 3)
        #expect(diffCalls.allSatisfy { arguments in
            arguments.contains("--no-color") &&
                arguments.contains("--no-ext-diff") &&
                arguments.contains("-z")
        })
        #expect(calls.filter { $0.contains("--numstat") }.count == 1)
        #expect(calls.filter { $0.contains("ls-files") }.count == 1)
    }
}
