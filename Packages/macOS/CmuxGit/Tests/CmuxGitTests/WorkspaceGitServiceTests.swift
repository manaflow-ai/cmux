import Foundation
import Testing

@testable import CmuxGit

@Suite struct WorkspaceGitServiceTests {
    @Test func readsNonemptyUntrackedStatsInProcess() async throws {
        let repository = try RealGitRepository()
        try repository.write("notes.txt", contents: "one\ntwo\n")

        let status = try await WorkspaceGitService().status(forDirectory: repository.root.path)

        let file = try #require(status.files.first)
        #expect(file.path == "notes.txt")
        #expect(file.additions == 2)
        #expect(file.deletions == 0)
        #expect(!file.binary)
        #expect(file.untracked)
        #expect(!status.truncatedUntracked)
    }

    @Test func detectsUntrackedBinaryFromBoundedPrefix() async throws {
        let repository = try RealGitRepository()
        try repository.write("image.bin", data: Data([0x41, 0x00, 0x0A]))

        let status = try await WorkspaceGitService().status(forDirectory: repository.root.path)

        let file = try #require(status.files.first)
        #expect(file.binary)
        #expect(file.additions == 0)
        #expect(file.deletions == 0)
    }

    @Test func unbornHeadUsesEmptyTreeForStatusAndPatch() async throws {
        let repository = try RealGitRepository()
        try repository.write("first.swift", contents: "let first = true\n")
        try repository.git(["add", "first.swift"])

        let service = WorkspaceGitService()
        let status = try await service.status(forDirectory: repository.root.path)
        let diff = try await service.diff(
            forDirectory: repository.root.path,
            paths: [WorkspaceGitDiffPath(path: "first.swift")]
        )

        let file = try #require(status.files.first)
        #expect(file.status == "A")
        #expect(file.additions == 1)
        #expect(diff.included == ["first.swift"])
        #expect(diff.patch.contains("new file mode"))
        #expect(diff.patch.contains("+let first = true"))
    }

    @Test func renamePatchIncludesRenameHeadersAndRawUnicodePaths() async throws {
        let repository = try RealGitRepository()
        try repository.write("旧.swift", contents: "let value = 1\n")
        try repository.git(["add", "旧.swift"])
        try repository.git(["commit", "--quiet", "-m", "initial"])
        try repository.git(["mv", "旧.swift", "新.swift"])

        let service = WorkspaceGitService()
        let status = try await service.status(forDirectory: repository.root.path)
        let renamed = try #require(status.files.first(where: { $0.status == "R" }))
        let diff = try await service.diff(
            forDirectory: repository.root.path,
            paths: [WorkspaceGitDiffPath(path: renamed.path, oldPath: renamed.oldPath)]
        )

        #expect(renamed.path == "新.swift")
        #expect(renamed.oldPath == "旧.swift")
        #expect(diff.patch.contains("rename from 旧.swift"))
        #expect(diff.patch.contains("rename to 新.swift"))
        #expect(!diff.patch.contains("\\346\\227"))
    }

    @Test func capsUntrackedEntriesAndReportsTruncation() async throws {
        let repository = try RealGitRepository()
        for index in 0...WorkspaceGitService.maximumUntrackedEntries {
            try repository.write("untracked/\(index).txt", contents: "")
        }

        let status = try await WorkspaceGitService().status(forDirectory: repository.root.path)

        #expect(status.files.count == WorkspaceGitService.maximumUntrackedEntries)
        #expect(status.files.allSatisfy { $0.untracked })
        #expect(status.truncatedUntracked)
    }
}
