import Foundation
import Testing
@testable import CmuxGit

@Suite struct WorkspaceChangesServiceTests {
    @Test func branchCommitsAndDirtyWorktreeShareOneScope() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.makeBaseline()
        try repo.git(["switch", "-c", "feature/changes"])
        try repo.write("committed.txt", "committed\n")
        try repo.git(["add", "committed.txt"])
        try repo.commit("feature commit")
        try repo.write("tracked.txt", "base\ndirty\n")
        try repo.write("staged.txt", "staged\n")
        try repo.git(["add", "staged.txt"])
        try repo.write("untracked.txt", "one\ntwo\n")

        let result = await WorkspaceChangesService().changedFiles(forDirectory: repo.root.path)

        #expect(result.isRepository)
        #expect(result.branch == "feature/changes")
        #expect(result.baseRef == "main")
        #expect(Set(result.files.map(\.path)) == [
            "committed.txt", "staged.txt", "tracked.txt", "untracked.txt",
        ])
        #expect(result.files.first(where: { $0.path == "untracked.txt" })?.status == .untracked)
        #expect(result.additions >= 5)
    }

    @Test func mainBranchDirtyWorktreeFallsBackToHead() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.makeBaseline()
        try repo.write("tracked.txt", "changed\n")

        let result = await WorkspaceChangesService().changedFiles(forDirectory: repo.root.path)

        #expect(result.branch == "main")
        #expect(result.baseRef == nil)
        #expect(result.files.map(\.path) == ["tracked.txt"])
    }

    @Test func untrackedFileCountsAddedLines() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.makeBaseline()
        try repo.write("new.txt", "one\ntwo\nthree\n")

        let result = await WorkspaceChangesService().changedFiles(forDirectory: repo.root.path)
        let file = try #require(result.files.first(where: { $0.path == "new.txt" }))

        #expect(file.status == .untracked)
        #expect(file.additions == 3)
        #expect(file.deletions == 0)
        #expect(!file.isBinary)
    }

    @Test func detectsRenameWithOldPath() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.write("old-name.txt", "enough content for rename detection\nsecond line\n")
        try repo.git(["add", "old-name.txt"])
        try repo.commit("baseline")
        try repo.git(["mv", "old-name.txt", "new-name.txt"])

        let result = await WorkspaceChangesService().changedFiles(forDirectory: repo.root.path)
        let file = try #require(result.files.first)
        let diff = try await WorkspaceChangesService().fileDiff(
            forDirectory: repo.root.path,
            path: "new-name.txt"
        )

        #expect(file.status == .renamed)
        #expect(file.path == "new-name.txt")
        #expect(file.oldPath == "old-name.txt")
        #expect(diff.status == .renamed)
        #expect(diff.oldPath == "old-name.txt")
        #expect(!diff.unifiedDiff.isEmpty)
    }

    @Test func binaryFileHasZeroLineCountsAndEmptyDiff() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.write("binary.dat", Data([0, 1, 2, 3]))
        try repo.git(["add", "binary.dat"])
        try repo.commit("binary baseline")
        try repo.write("binary.dat", Data([0, 1, 9, 3, 4]))
        let service = WorkspaceChangesService()

        let files = await service.changedFiles(forDirectory: repo.root.path)
        let file = try #require(files.files.first)
        let diff = try await service.fileDiff(forDirectory: repo.root.path, path: "binary.dat")

        #expect(file.isBinary)
        #expect(file.additions == 0)
        #expect(file.deletions == 0)
        #expect(diff.isBinary)
        #expect(diff.unifiedDiff.isEmpty)
    }

    @Test func deletedFileReportsDeletions() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.write("delete-me.txt", "one\ntwo\n")
        try repo.git(["add", "delete-me.txt"])
        try repo.commit("delete baseline")
        try repo.remove("delete-me.txt")

        let service = WorkspaceChangesService()
        let result = await service.changedFiles(forDirectory: repo.root.path)
        let file = try #require(result.files.first)
        let diff = try await service.fileDiff(
            forDirectory: repo.root.path,
            path: "delete-me.txt"
        )

        #expect(file.status == .deleted)
        #expect(file.deletions == 2)
        #expect(diff.contentFingerprint == nil)
    }

    @Test func notARepositoryReturnsSentinels() async throws {
        let directory = try WorkspaceChangesGitRepositoryFixture(initializeRepository: false)
        let service = WorkspaceChangesService()

        let summary = await service.summary(forDirectory: directory.root.path)
        let files = await service.changedFiles(forDirectory: directory.root.path)

        #expect(summary == .notARepository)
        #expect(files == .notARepository)
    }

    @Test func fileDiffRejectsEscapingPath() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.makeBaseline()
        try repo.write("tracked.txt", "dirty\n")

        await #expect(throws: WorkspaceChangesServiceError.invalidPath) {
            try await WorkspaceChangesService().fileDiff(
                forDirectory: repo.root.path,
                path: "../outside.txt"
            )
        }
    }

    @Test func fileDiffTruncatesMoreThanSixThousandLines() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        let baseline = (0..<6_500).map { "old-\($0)" }.joined(separator: "\n") + "\n"
        let changed = (0..<6_500).map { "new-\($0)" }.joined(separator: "\n") + "\n"
        try repo.write("large.txt", baseline)
        try repo.git(["add", "large.txt"])
        try repo.commit("large baseline")
        try repo.write("large.txt", changed)

        let diff = try await WorkspaceChangesService().fileDiff(
            forDirectory: repo.root.path,
            path: "large.txt"
        )

        #expect(diff.truncated)
        #expect(diff.unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false).count <= 6_000)
        #expect(diff.unifiedDiff.utf8.count <= 400 * 1024)
        #expect(try #require(diff.totalLineCount) > 6_000)
    }

    @Test func fileDiffLargerLineBudgetExpandsOversizedHunkAndReportsTotal() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        let baseline = (0..<6_500).map { "old-\($0)" }.joined(separator: "\n") + "\n"
        let changed = (0..<6_500).map { "new-\($0)" }.joined(separator: "\n") + "\n"
        try repo.write("large.txt", baseline)
        try repo.git(["add", "large.txt"])
        try repo.commit("large baseline")
        try repo.write("large.txt", changed)
        let service = WorkspaceChangesService()

        let defaultDiff = try await service.fileDiff(
            forDirectory: repo.root.path,
            path: "large.txt"
        )
        let expandedDiff = try await service.fileDiff(
            forDirectory: repo.root.path,
            path: "large.txt",
            maxLines: 24_000
        )

        #expect(defaultDiff.truncated)
        #expect(!expandedDiff.truncated)
        #expect(expandedDiff.unifiedDiff.count > defaultDiff.unifiedDiff.count)
        #expect(expandedDiff.totalLineCount == defaultDiff.totalLineCount)
        #expect(
            expandedDiff.totalLineCount ==
                expandedDiff.unifiedDiff.split(
                    separator: "\n",
                    omittingEmptySubsequences: false
                ).count
        )
    }

    @Test func boundedDiffReadLeavesTotalLineCountUnknown() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        let oldLine = String(repeating: "a", count: 80)
        let newLine = String(repeating: "b", count: 80)
        let baseline = (0..<20_000).map { "\(oldLine)-\($0)" }.joined(separator: "\n") + "\n"
        let changed = (0..<20_000).map { "\(newLine)-\($0)" }.joined(separator: "\n") + "\n"
        try repo.write("transport-ceiling.txt", baseline)
        try repo.git(["add", "transport-ceiling.txt"])
        try repo.commit("transport ceiling baseline")
        try repo.write("transport-ceiling.txt", changed)

        let diff = try await WorkspaceChangesService().fileDiff(
            forDirectory: repo.root.path,
            path: "transport-ceiling.txt"
        )

        #expect(diff.truncated)
        #expect(diff.totalLineCount == nil)
        #expect(diff.unifiedDiff.utf8.count <= 400 * 1024)
    }

    @Test func fallsBackToLocalMainWhenOriginHeadIsAbsent() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.makeBaseline()
        try repo.git(["switch", "-c", "feature/local-main"])
        try repo.write("feature.txt", "feature\n")
        try repo.git(["add", "feature.txt"])
        try repo.commit("feature")

        let result = await WorkspaceChangesService().changedFiles(forDirectory: repo.root.path)

        #expect(result.baseRef == "main")
        #expect(result.files.map(\.path) == ["feature.txt"])
    }
}
