import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxGit

@Suite struct WorkspaceChangesContentTests {
    @Test func authorizesOnlyChangedPathsForTheRequestedRevision() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.write("changed.bin", Data([0, 1, 2]))
        try repo.write("unchanged.bin", Data([3, 4, 5]))
        try repo.git(["add", "changed.bin", "unchanged.bin"])
        try repo.commit("baseline")
        try repo.write("changed.bin", Data([0, 9, 2]))
        let service = WorkspaceChangesService()

        let stat = try await service.fileStat(
            forDirectory: repo.root.path,
            path: "changed.bin",
            revision: .current
        )
        #expect(stat.size == 3)

        await #expect(throws: WorkspaceChangesServiceError.forbidden) {
            try await service.fileStat(
                forDirectory: repo.root.path,
                path: "unchanged.bin",
                revision: .current
            )
        }
    }

    @Test func renameOldPathIsAuthorizedOnlyAtBase() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        let contents = Data("rename source with enough stable content\nsecond line\n".utf8)
        try repo.write("old-name.dat", contents)
        try repo.git(["add", "old-name.dat"])
        try repo.commit("baseline")
        try repo.git(["mv", "old-name.dat", "new-name.dat"])
        let service = WorkspaceChangesService()

        let base = try await service.fileFetch(
            forDirectory: repo.root.path,
            path: "old-name.dat",
            revision: .base,
            offset: 0,
            length: 1024
        )
        #expect(base.data == contents)
        #expect(base.eof)

        await #expect(throws: WorkspaceChangesServiceError.forbidden) {
            try await service.fileFetch(
                forDirectory: repo.root.path,
                path: "old-name.dat",
                revision: .current,
                offset: 0,
                length: 1024
            )
        }
    }

    @Test func baseCacheServesStableSlicesWithCorrectEOFMath() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        let baseline = Data((0..<64).map(UInt8.init))
        try repo.write("payload.bin", baseline)
        try repo.git(["add", "payload.bin"])
        try repo.commit("baseline")
        try repo.write("payload.bin", Data(repeating: 0xFF, count: baseline.count))
        let service = WorkspaceChangesService()

        let middle = try await service.fileFetch(
            forDirectory: repo.root.path,
            path: "payload.bin",
            revision: .base,
            offset: 7,
            length: 11
        )
        try repo.git(["add", "payload.bin"])
        try repo.commit("replace base after first materialization")
        let end = try await service.fileFetch(
            forDirectory: repo.root.path,
            path: "payload.bin",
            revision: .base,
            offset: 60,
            length: 50
        )

        #expect(middle.data == baseline.subdata(in: 7..<18))
        #expect(middle.offset == 7)
        #expect(middle.totalSize == 64)
        #expect(!middle.eof)
        #expect(end.data == baseline.subdata(in: 60..<64))
        #expect(end.offset == 60)
        #expect(end.totalSize == 64)
        #expect(end.eof)
    }

    @Test func currentRevisionSlicesFilesLargerThanOneChunk() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.write("large.bin", Data([0]))
        try repo.git(["add", "large.bin"])
        try repo.commit("baseline")
        let maximum = ChatArtifactTransferPolicy.defaultPolicy.maxRawChunkBytes
        let current = Data((0..<(maximum + 37)).map { UInt8($0 % 251) })
        try repo.write("large.bin", current)
        let service = WorkspaceChangesService()

        let first = try await service.fileFetch(
            forDirectory: repo.root.path,
            path: "large.bin",
            revision: .current,
            offset: 0,
            length: maximum * 2
        )
        let second = try await service.fileFetch(
            forDirectory: repo.root.path,
            path: "large.bin",
            revision: .current,
            offset: Int64(first.data.count),
            length: maximum
        )

        #expect(first.data.count == maximum)
        #expect(first.totalSize == Int64(current.count))
        #expect(!first.eof)
        #expect(second.data == Data(current.suffix(37)))
        #expect(second.offset == Int64(maximum))
        #expect(second.eof)
    }

    @Test func oversizedBaseBlobIsRefusedBeforeMaterialization() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-oversized-base-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeWorkspaceChangesGitRunner(results: [
            ["rev-parse", "--show-toplevel"]: FakeWorkspaceChangesGitRunner.result("\(root.path)\n"),
            ["symbolic-ref", "--quiet", "--short", "HEAD"]: FakeWorkspaceChangesGitRunner.result("main\n"),
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "origin/main^{commit}"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "origin/master^{commit}"]: FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "main^{commit}"]: FakeWorkspaceChangesGitRunner.result("abc\n"),
            ["diff", "-M", "--name-status", "-z", "HEAD", "--"]: FakeWorkspaceChangesGitRunner.result("M\0large.bin\0"),
            ["diff", "-M", "--numstat", "-z", "HEAD", "--"]: FakeWorkspaceChangesGitRunner.result("1\t1\tlarge.bin\0"),
            ["ls-files", "--others", "--exclude-standard", "-z"]: FakeWorkspaceChangesGitRunner.result(),
            ["cat-file", "-s", "HEAD:large.bin"]: FakeWorkspaceChangesGitRunner.result("5\n"),
        ])
        let cache = WorkspaceChangesBaseContentCache(
            byteBudget: 4,
            temporaryDirectory: root
        )
        let service = WorkspaceChangesService(runner: runner, baseContentCache: cache)

        await #expect(throws: WorkspaceChangesServiceError.gitFailure) {
            try await service.fileStat(
                forDirectory: root.path,
                path: "large.bin",
                revision: .base
            )
        }
    }

    @Test func baseCacheRejectsOversizedEntriesAndEvictsLeastRecentlyUsed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-base-cache-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WorkspaceChangesBaseContentCache(byteBudget: 4, temporaryDirectory: root)
        let oversized = WorkspaceChangesBaseContentCache.Key(
            repoRoot: "/repo",
            baseRef: "HEAD",
            path: "oversized"
        )

        await #expect(throws: WorkspaceChangesBaseContentCache.Error.entryExceedsByteBudget) {
            try await cache.fileURL(for: oversized) { destination in
                try Data("12345".utf8).write(to: destination)
                return 5
            }
        }
        let recovered = try await cache.fileURL(for: oversized) { destination in
            try Data("x".utf8).write(to: destination)
            return 1
        }
        #expect(try Data(contentsOf: recovered) == Data("x".utf8))

        let second = WorkspaceChangesBaseContentCache.Key(
            repoRoot: "/repo",
            baseRef: "HEAD",
            path: "second"
        )
        let third = WorkspaceChangesBaseContentCache.Key(
            repoRoot: "/repo",
            baseRef: "HEAD",
            path: "third"
        )
        let secondURL = try await cache.fileURL(for: second) { destination in
            try Data("22".utf8).write(to: destination)
            return 2
        }
        _ = try await cache.fileURL(for: third) { destination in
            try Data("333".utf8).write(to: destination)
            return 3
        }
        #expect(!FileManager.default.fileExists(atPath: recovered.path))
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))
    }
}
