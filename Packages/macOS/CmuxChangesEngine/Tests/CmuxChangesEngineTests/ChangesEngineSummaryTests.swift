import CmuxChangesEngine
import Foundation
import Testing

@Suite
struct ChangesEngineSummaryTests {
    @Test
    func trackedStatusesIncludeContentSimilarRenameAndCopy() async throws {
        let fixture = try await GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("modified.txt", "before\n")
        try fixture.write("deleted.txt", "gone\n")
        try fixture.write("old.txt", (1...30).map { "rename \($0)" }.joined(separator: "\n") + "\n")
        try fixture.write("copy-source.txt", "copy one\ncopy two\ncopy three\n")
        try await fixture.commitAll("baseline")

        try fixture.write("modified.txt", "after\n")
        try fixture.remove("deleted.txt")
        _ = try await fixture.git(["mv", "old.txt", "renamed.txt"])
        try fixture.write("renamed.txt", (1...29).map { "rename \($0)" }.joined(separator: "\n") + "\nchanged\n")
        try fixture.write("added.txt", "new\n")
        try fixture.write("copied.txt", "copy one\ncopy two\ncopy three\n")
        _ = try await fixture.git(["add", "added.txt", "renamed.txt", "copied.txt"])

        let summary = try await ChangesEngine().summary(
            repoRoot: fixture.root.path,
            base: .workingTree,
            ignoreWhitespace: false
        )
        let byPath = Dictionary(uniqueKeysWithValues: summary.files.map { ($0.path, $0) })
        #expect(byPath["modified.txt"]?.status == .modified)
        #expect(byPath["deleted.txt"]?.status == .deleted)
        #expect(byPath["added.txt"]?.status == .added)
        #expect(byPath["renamed.txt"]?.status == .renamed)
        #expect(byPath["renamed.txt"]?.oldPath == "old.txt")
        #expect(byPath["copied.txt"]?.status == .copied)
        #expect(byPath["copied.txt"]?.oldPath == "copy-source.txt")
    }

    @Test
    func untrackedTextAndBinaryAreCountedInProcess() async throws {
        let fixture = try await GitFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.git([
            "-c", "user.email=fixture@example.com", "-c", "user.name=Fixture",
            "commit", "--allow-empty", "-qm", "empty",
        ])
        try fixture.write("notes.txt", "one\ntwo\n")
        try fixture.write("blob.bin", Data([0x41, 0x00, 0x42]))

        let summary = try await ChangesEngine().summary(
            repoRoot: fixture.root.path,
            base: .workingTree,
            ignoreWhitespace: false
        )
        let byPath = Dictionary(uniqueKeysWithValues: summary.files.map { ($0.path, $0) })
        #expect(byPath["notes.txt"]?.status == .untracked)
        #expect(byPath["notes.txt"]?.additions == 2)
        #expect(byPath["notes.txt"]?.isBinary == false)
        #expect(byPath["blob.bin"]?.status == .untracked)
        #expect(byPath["blob.bin"]?.additions == 0)
        #expect(byPath["blob.bin"]?.isBinary == true)
    }

    @Test
    func trackedBinaryChangeUsesNumstatBinaryMarker() async throws {
        let fixture = try await GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("image.bin", Data([0x00, 0x01, 0x02, 0x03]))
        try await fixture.commitAll("binary")
        try fixture.write("image.bin", Data([0x00, 0x01, 0x04, 0x05]))

        let summary = try await ChangesEngine().summary(
            repoRoot: fixture.root.path,
            base: .workingTree,
            ignoreWhitespace: false
        )
        let file = try #require(summary.files.first)
        #expect(file.status == .modified)
        #expect(file.isBinary)
        #expect(file.additions == 0)
        #expect(file.deletions == 0)
    }

    @Test
    func unbornHeadUsesEmptyTreeForStagedAndUntrackedFiles() async throws {
        let fixture = try await GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("staged.txt", "staged\n")
        try fixture.write("loose.txt", "loose\n")
        _ = try await fixture.git(["add", "staged.txt"])

        let summary = try await ChangesEngine().summary(
            repoRoot: fixture.root.path,
            base: .workingTree,
            ignoreWhitespace: false
        )
        let byPath = Dictionary(uniqueKeysWithValues: summary.files.map { ($0.path, $0) })
        #expect(summary.baseInfo.resolvedRef == "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
        #expect(byPath["staged.txt"]?.status == .added)
        #expect(byPath["loose.txt"]?.status == .untracked)
        #expect(summary.totals.additions == 2)
    }

    @Test
    func ignoreWhitespaceSuppressesWhitespaceOnlyTrackedChange() async throws {
        let fixture = try await GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("spaces.txt", "hello world\n")
        try await fixture.commitAll("spaces")
        try fixture.write("spaces.txt", "hello     world\n")

        let engine = ChangesEngine()
        let included = try await engine.summary(
            repoRoot: fixture.root.path,
            base: .workingTree,
            ignoreWhitespace: false
        )
        let ignored = try await engine.summary(
            repoRoot: fixture.root.path,
            base: .workingTree,
            ignoreWhitespace: true
        )
        #expect(included.files.map(\.path) == ["spaces.txt"])
        #expect(ignored.files.isEmpty)
    }

    @Test
    func largeFileGateUsesLineThreshold() async throws {
        let fixture = try await GitFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.git([
            "-c", "user.email=fixture@example.com", "-c", "user.name=Fixture",
            "commit", "--allow-empty", "-qm", "empty",
        ])
        try fixture.write("large.txt", (1...3_001).map { "line \($0)" }.joined(separator: "\n") + "\n")

        let summary = try await ChangesEngine().summary(
            repoRoot: fixture.root.path,
            base: .workingTree,
            ignoreWhitespace: false
        )
        let file = try #require(summary.files.first)
        #expect(file.additions == 3_001)
        #expect(file.isLarge)
    }

    @Test
    func patchDigestIsStableUntilContentChanges() async throws {
        let fixture = try await GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("digest.txt", "base\n")
        try await fixture.commitAll("digest")
        try fixture.write("digest.txt", "first\n")
        let engine = ChangesEngine()

        let first = try await engine.summary(repoRoot: fixture.root.path, base: .workingTree, ignoreWhitespace: false)
        let repeated = try await engine.summary(repoRoot: fixture.root.path, base: .workingTree, ignoreWhitespace: false)
        try fixture.write("digest.txt", "second\n")
        let changed = try await engine.summary(repoRoot: fixture.root.path, base: .workingTree, ignoreWhitespace: false)

        #expect(first.files.first?.patchDigest == repeated.files.first?.patchDigest)
        #expect(first.files.first?.patchDigest != changed.files.first?.patchDigest)
        #expect(first.files.first?.patchDigest.count == 64)
    }

    @Test
    func branchBaseResolvesMergeBaseWithDefaultBranch() async throws {
        let fixture = try await GitFixture()
        defer { fixture.cleanup() }
        try fixture.write("base.txt", "base\n")
        try await fixture.commitAll("base")
        _ = try await fixture.git(["branch", "-M", "main"])
        let baseline = try await fixture.git(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await fixture.git(["checkout", "-qb", "feature"])
        try fixture.write("feature.txt", "feature\n")
        try await fixture.commitAll("feature")

        let base = try await ChangesEngine().branchBase(repoRoot: fixture.root.path)
        #expect(base == .ref(baseline))
    }

    @Test
    func summaryBatchesStatusStatsAndPatchAcrossUntrackedFiles() async throws {
        let fixture = try await GitFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.git([
            "-c", "user.email=fixture@example.com", "-c", "user.name=Fixture",
            "commit", "--allow-empty", "-qm", "empty",
        ])
        try fixture.write("one.txt", "one\n")
        try fixture.write("two.txt", "two\n")
        let recorder = RecordingCommandRunner()

        _ = try await ChangesEngine(commandRunner: recorder).summary(
            repoRoot: fixture.root.path,
            base: .workingTree,
            ignoreWhitespace: false
        )
        let invocations = await recorder.recordedArguments()
        #expect(invocations.filter { $0.contains("status") }.count == 1)
        #expect(invocations.filter { $0.contains("--numstat") }.count == 1)
        #expect(invocations.filter { $0.contains("--patch") }.count == 1)
        #expect(invocations.count == 4)
    }

    @Test
    func nulDelimitedTrackedPathIsNeverRecoveredFromQuotedPatchHeaders() async throws {
        let fixture = try await GitFixture()
        defer { fixture.cleanup() }
        let path = "odd\t雪\nname.txt"
        try fixture.write(path, "before\n")
        try await fixture.commitAll("odd path")
        try fixture.write(path, "after\n")

        let summary = try await ChangesEngine().summary(
            repoRoot: fixture.root.path,
            base: .workingTree,
            ignoreWhitespace: false
        )
        #expect(summary.files.map(\.path) == [path])
        #expect(summary.files.first?.status == .modified)
    }
}
