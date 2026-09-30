import Foundation
import Testing

@testable import CmuxGit

@Suite struct WorkspaceChangesBaseFingerprintTests {
    @Test func rematerializedBaseEntryKeepsImmutableBlobFingerprint() async throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.write("first.txt", "first base\n")
        try repo.write("second.txt", "second base\n")
        try repo.git(["add", "first.txt", "second.txt"])
        try repo.commit("baseline")
        let baseCommitOID = String(
            decoding: try repo.git(["rev-parse", "HEAD"]),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let firstBlobOID = String(
            decoding: try repo.git(["rev-parse", "\(baseCommitOID):first.txt"]),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.write("first.txt", "first current\n")
        try repo.write("second.txt", "second current\n")
        let cache = WorkspaceChangesBaseContentCache(
            byteBudget: 1_024,
            maximumEntryCount: 1,
            temporaryDirectory: repo.root
        )
        let service = WorkspaceChangesService(
            runner: SystemWorkspaceChangesGitRunner(),
            baseContentCache: cache
        )

        let original = try await service.fileStat(
            forDirectory: repo.root.path,
            path: "first.txt",
            revision: .base
        )
        _ = try await service.fileStat(
            forDirectory: repo.root.path,
            path: "second.txt",
            revision: .base
        )
        let rematerialized = try await service.fileFetch(
            forDirectory: repo.root.path,
            path: "first.txt",
            revision: .base,
            offset: 0,
            length: 1_024
        )

        let expected = "blob:\(baseCommitOID):\(firstBlobOID)"
        #expect(original.contentFingerprint == expected)
        #expect(rematerialized.contentFingerprint == expected)
        #expect(rematerialized.data == Data("first base\n".utf8))
    }
}
