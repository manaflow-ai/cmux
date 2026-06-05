import Foundation
import Testing
@testable import CmuxGit

@Suite(.serialized) struct GitMetadataServiceIndexStressTests {
    @Test func malformedPartialAndUnsupportedIndexesReturnNilGracefully() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        let repository = try #require(GitMetadataService.resolveGitRepository(containing: fixture.root.path))
        let indexURL = fixture.gitDirectory.appendingPathComponent("index")
        let validIndex = GitIndexFixture(version: 2, entries: [
            GitIndexFixture.Entry(path: "tracked.txt"),
        ]).data()
        let unsupportedVersionIndex = GitIndexFixture(version: 99, entries: []).data()
        let truncatedEntryHeader = Data(validIndex.prefix(12 + 20))
        let missingPathTerminator = Self.indexDataWithMissingPathTerminator()
        let truncatedV4StripLength = Self.truncatedVersionFourStripLengthIndexData()
        let extendedFlagsWithoutPayload = Self.extendedFlagsWithoutPayloadIndexData()

        let malformedIndexes = [
            Data(),
            Data("not an index".utf8),
            Data(validIndex.prefix(31)),
            unsupportedVersionIndex,
            truncatedEntryHeader,
            missingPathTerminator,
            truncatedV4StripLength,
            extendedFlagsWithoutPayload,
        ]

        for malformedIndex in malformedIndexes {
            try malformedIndex.write(to: indexURL)
            #expect(GitMetadataService.gitIndexSnapshot(indexURL: indexURL) == nil)

            let trackedChanges = GitMetadataService.gitTrackedChangesSnapshot(repository: repository)
            #expect(!trackedChanges.isDirty)
            #expect(trackedChanges.indexContentSignature == nil)
        }
    }

    @Test func indexLockDoesNotChangePointInTimeIndexParsing() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch("main")
        try fixture.writeIndex(GitIndexFixture(version: 2, entries: [
            GitIndexFixture.Entry(path: "tracked.txt"),
        ]))
        let indexURL = fixture.gitDirectory.appendingPathComponent("index")
        let lockURL = fixture.gitDirectory.appendingPathComponent("index.lock")

        try Data("partial rewrite".utf8).write(to: lockURL)
        defer {
            try? FileManager.default.removeItem(at: lockURL)
        }

        let snapshot = try #require(GitMetadataService.gitIndexSnapshot(indexURL: indexURL))
        #expect(snapshot.entries.map(\.path) == ["tracked.txt"])
    }

    @Test(.timeLimit(.seconds(30)))
    func concurrentParsingSurvivesTornIndexRewritesAcrossLinkedWorktrees() async throws {
        let fixture = try Self.makeLinkedWorktreeFixture(count: 4)
        defer {
            try? FileManager.default.removeItem(at: fixture.baseURL)
        }

        let variantsByIndexURL = fixture.indexURLs.reduce(into: [URL: [Data]]()) { result, indexURL in
            let validIndex = fixture.validIndexDataByURL[indexURL] ?? Data()
            result[indexURL] = Self.indexRewriteVariants(validIndex: validIndex)
        }
        for indexURL in fixture.indexURLs {
            let variants = try #require(variantsByIndexURL[indexURL])
            try variants[1].write(to: indexURL)
            #expect(GitMetadataService.gitIndexSnapshot(indexURL: indexURL) == nil)
            try variants[0].write(to: indexURL)
            #expect(GitMetadataService.gitIndexSnapshot(indexURL: indexURL) != nil)
        }

        let observations = try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            group.addTask {
                try await Self.rewriteIndexesConcurrently(variantsByIndexURL: variantsByIndexURL, iterations: 240)
                return (0, 0)
            }

            for repository in fixture.repositories {
                group.addTask {
                    var parsedCount = 0
                    var nilCount = 0
                    let indexURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index")
                    for _ in 0..<240 {
                        if GitMetadataService.gitIndexSnapshot(indexURL: indexURL) == nil {
                            nilCount += 1
                        } else {
                            parsedCount += 1
                        }
                        _ = GitMetadataService.gitTrackedChangesSnapshot(repository: repository)
                        await Task.yield()
                    }
                    return (parsedCount, nilCount)
                }
            }

            var parsedCount = 0
            var nilCount = 0
            for try await result in group {
                parsedCount += result.0
                nilCount += result.1
            }
            return (parsedCount, nilCount)
        }

        #expect(observations.0 > 0)
        #expect(observations.0 + observations.1 == fixture.repositories.count * 240)
        for indexURL in fixture.indexURLs {
            #expect(GitMetadataService.gitIndexSnapshot(indexURL: indexURL) != nil)
        }
    }

    private static func indexRewriteVariants(validIndex: Data) -> [Data] {
        [
            validIndex,
            Data(validIndex.prefix(8)),
            Data(validIndex.prefix(31)),
            Data(validIndex.prefix(max(0, validIndex.count - 7))),
            GitIndexFixture(version: 99, entries: []).data(),
            Self.indexDataWithMissingPathTerminator(),
            Self.truncatedVersionFourStripLengthIndexData(),
            Self.extendedFlagsWithoutPayloadIndexData(),
        ]
    }

    private static func rewriteIndexesConcurrently(
        variantsByIndexURL: [URL: [Data]],
        iterations: Int
    ) async throws {
        let fileManager = FileManager.default
        for iteration in 0..<iterations {
            for (indexURL, variants) in variantsByIndexURL {
                let lockURL = indexURL.deletingLastPathComponent().appendingPathComponent("index.lock")
                try? Data("lock-\(iteration)".utf8).write(to: lockURL)
                try variants[iteration % variants.count].write(to: indexURL)
                try? fileManager.removeItem(at: lockURL)
            }
            await Task.yield()
        }

        for (indexURL, variants) in variantsByIndexURL {
            try variants[0].write(to: indexURL)
        }
    }

    private static func makeLinkedWorktreeFixture(count: Int) throws -> (
        baseURL: URL,
        repositories: [ResolvedGitRepository],
        indexURLs: [URL],
        validIndexDataByURL: [URL: Data]
    ) {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmuxgit-linked-worktrees-\(UUID().uuidString)", isDirectory: true)
        let commonGitDirectory = baseURL.appendingPathComponent("main.git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: commonGitDirectory.appendingPathComponent("refs/heads", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: commonGitDirectory.appendingPathComponent("worktrees", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "\(String(repeating: "f", count: 40))\n".write(
            to: commonGitDirectory.appendingPathComponent("refs/heads/main"),
            atomically: true,
            encoding: .utf8
        )

        var repositories: [ResolvedGitRepository] = []
        var indexURLs: [URL] = []
        var validIndexDataByURL: [URL: Data] = [:]
        for index in 0..<count {
            let worktreeURL = baseURL.appendingPathComponent("worktree-\(index)", isDirectory: true)
            let gitDirectory = commonGitDirectory
                .appendingPathComponent("worktrees", isDirectory: true)
                .appendingPathComponent("worktree-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
            try "gitdir: \(gitDirectory.path)\n".write(
                to: worktreeURL.appendingPathComponent(".git"),
                atomically: true,
                encoding: .utf8
            )
            try "../..".write(
                to: gitDirectory.appendingPathComponent("commondir"),
                atomically: true,
                encoding: .utf8
            )
            try "ref: refs/heads/main\n".write(
                to: gitDirectory.appendingPathComponent("HEAD"),
                atomically: true,
                encoding: .utf8
            )

            let entry = try Self.writeTrackedFile(named: "tracked-\(index).txt", in: worktreeURL)
            let validIndex = GitIndexFixture(version: 2, entries: [entry]).data()
            let indexURL = gitDirectory.appendingPathComponent("index")
            try validIndex.write(to: indexURL)
            let repository = try #require(GitMetadataService.resolveGitRepository(containing: worktreeURL.path))
            repositories.append(repository)
            indexURLs.append(indexURL)
            validIndexDataByURL[indexURL] = validIndex
        }

        return (baseURL, repositories, indexURLs, validIndexDataByURL)
    }

    private static func writeTrackedFile(named name: String, in worktreeURL: URL) throws -> GitIndexFixture.Entry {
        let fileURL = worktreeURL.appendingPathComponent(name)
        try "tracked contents for \(name)".write(to: fileURL, atomically: true, encoding: .utf8)

        var statValue = stat()
        _ = lstat(fileURL.path, &statValue)
        return GitIndexFixture.Entry(
            path: name,
            mode: (statValue.st_mode & S_IXUSR) == 0 ? 0o100644 : 0o100755,
            mtimeSeconds: UInt32(truncatingIfNeeded: statValue.st_mtimespec.tv_sec),
            mtimeNanoseconds: UInt32(truncatingIfNeeded: statValue.st_mtimespec.tv_nsec),
            size: UInt32(truncatingIfNeeded: statValue.st_size)
        )
    }

    private static func indexDataWithMissingPathTerminator() -> Data {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: Array("DIRC".utf8))
        bytes.append(contentsOf: GitIndexFixture.bigEndianUInt32(2))
        bytes.append(contentsOf: GitIndexFixture.bigEndianUInt32(1))
        bytes.append(contentsOf: Array(repeating: 0, count: 40))
        bytes.append(contentsOf: GitIndexFixture.hexBytes(String(repeating: "a", count: 40)))
        bytes.append(contentsOf: GitIndexFixture.bigEndianUInt16(0x0fff))
        bytes.append(contentsOf: Array("unterminated/path".utf8))
        bytes.append(contentsOf: Array(repeating: 0xAB, count: 20))
        return Data(bytes)
    }

    private static func truncatedVersionFourStripLengthIndexData() -> Data {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: Array("DIRC".utf8))
        bytes.append(contentsOf: GitIndexFixture.bigEndianUInt32(4))
        bytes.append(contentsOf: GitIndexFixture.bigEndianUInt32(1))
        bytes.append(contentsOf: Array(repeating: 0, count: 40))
        bytes.append(contentsOf: GitIndexFixture.hexBytes(String(repeating: "b", count: 40)))
        bytes.append(contentsOf: GitIndexFixture.bigEndianUInt16(1))
        bytes.append(0x80)
        bytes.append(contentsOf: Array(repeating: 0xAB, count: 20))
        return Data(bytes)
    }

    private static func extendedFlagsWithoutPayloadIndexData() -> Data {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: Array("DIRC".utf8))
        bytes.append(contentsOf: GitIndexFixture.bigEndianUInt32(3))
        bytes.append(contentsOf: GitIndexFixture.bigEndianUInt32(1))
        bytes.append(contentsOf: Array(repeating: 0, count: 40))
        bytes.append(contentsOf: GitIndexFixture.hexBytes(String(repeating: "c", count: 40)))
        bytes.append(contentsOf: GitIndexFixture.bigEndianUInt16(0x4001))
        bytes.append(contentsOf: Array(repeating: 0xAB, count: 20))
        return Data(bytes)
    }
}
