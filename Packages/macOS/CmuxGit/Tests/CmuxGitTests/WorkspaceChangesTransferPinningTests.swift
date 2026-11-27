import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxGit

@Suite struct WorkspaceChangesTransferPinningTests {
    @Test func chunkedBaseTransferRunsDiscoveryAndSizeCommandsOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pinned-base-transfer-\(UUID().uuidString)", isDirectory: true)
        let commandLog = root.appendingPathComponent("commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commandLog, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSize = 64 * 1_024 * 1_024
        let payload = Data(repeating: 0xA5, count: fileSize)
        let baseOID = "base-oid"
        let blobOID = "blob-oid"
        let results: [[String]: WorkspaceChangesGitResult] = [
            ["rev-parse", "--show-toplevel"]: FakeWorkspaceChangesGitRunner.result("\(root.path)\n"),
            ["symbolic-ref", "--quiet", "--short", "HEAD"]:
                FakeWorkspaceChangesGitRunner.result("main\n"),
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]:
                FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "origin/main^{commit}"]:
                FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "origin/master^{commit}"]:
                FakeWorkspaceChangesGitRunner.result(exitCode: 1),
            ["rev-parse", "--verify", "--quiet", "main^{commit}"]:
                FakeWorkspaceChangesGitRunner.result(baseOID),
            ["rev-parse", "--verify", "HEAD^{commit}"]:
                FakeWorkspaceChangesGitRunner.result(baseOID),
            ["diff", "-M", "--name-status", "-z", baseOID, "--"]:
                FakeWorkspaceChangesGitRunner.result("M\0large.bin\0"),
            ["diff", "-M", "--numstat", "-z", baseOID, "--"]:
                FakeWorkspaceChangesGitRunner.result("-\t-\tlarge.bin\0"),
            ["ls-files", "--others", "--exclude-standard", "-z"]:
                FakeWorkspaceChangesGitRunner.result(),
            ["--literal-pathspecs", "rev-parse", "\(baseOID):large.bin"]:
                FakeWorkspaceChangesGitRunner.result("\(blobOID)\n"),
            ["--literal-pathspecs", "cat-file", "-s", blobOID]:
                FakeWorkspaceChangesGitRunner.result("\(fileSize)\n"),
            ["--literal-pathspecs", "show", blobOID]:
                WorkspaceChangesGitResult(output: payload, exitCode: 0),
        ]
        let runner = FakeWorkspaceChangesGitRunner(
            results: results,
            beforeRun: { arguments, _ in
                guard arguments.first == "rev-parse"
                    || arguments.dropFirst().first == "rev-parse"
                    || arguments.dropFirst().first == "cat-file" else {
                    return
                }
                let marker = commandLog.appendingPathComponent(UUID().uuidString)
                try Data(arguments.joined(separator: "\u{1F}").utf8).write(to: marker)
            }
        )
        let service = WorkspaceChangesService(runner: runner)
        let chunkLength = ChatArtifactTransferPolicy.defaultPolicy.maxRawChunkBytes
        var offset: Int64 = 0
        var chunkCount = 0

        while offset < Int64(fileSize) {
            let chunk = try await service.fileFetch(
                forDirectory: root.path,
                path: "large.bin",
                revision: .base,
                offset: offset,
                length: chunkLength
            )
            #expect(chunk.offset == offset)
            offset = chunk.offset + Int64(chunk.data.count)
            chunkCount += 1
        }

        let recordedCommands = try FileManager.default.contentsOfDirectory(
            at: commandLog,
            includingPropertiesForKeys: nil
        ).map { marker in
            String(decoding: try Data(contentsOf: marker), as: UTF8.self)
        }
        let invocationCount: ([String]) -> Int = { arguments in
            let encoded = arguments.joined(separator: "\u{1F}")
            return recordedCommands.filter { $0 == encoded }.count
        }
        let revParseCommands = recordedCommands.filter { $0.hasPrefix("rev-parse\u{1F}") }

        #expect(chunkCount == 22)
        #expect(offset == Int64(fileSize))
        #expect(Set(revParseCommands).count == revParseCommands.count)
        #expect(invocationCount(["rev-parse", "--show-toplevel"]) == 1)
        #expect(invocationCount([
            "--literal-pathspecs", "rev-parse", "\(baseOID):large.bin",
        ]) == 1)
        #expect(invocationCount([
            "--literal-pathspecs", "cat-file", "-s", blobOID,
        ]) == 1)
    }

    @Test func leasedStatPathRejectsPressureAndSurvivesUntilUseCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-base-cache-leases-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WorkspaceChangesBaseContentCache(
            byteBudget: 4,
            maximumEntryCount: 2,
            temporaryDirectory: root
        )
        let firstKey = WorkspaceChangesBaseContentCache.Key(
            repoRoot: "/repo",
            baseCommitOID: "abc",
            path: "first"
        )
        let secondKey = WorkspaceChangesBaseContentCache.Key(
            repoRoot: "/repo",
            baseCommitOID: "abc",
            path: "second"
        )
        let rejectedMaterialization = root.appendingPathComponent("rejected")

        let survivingURL = try await cache.withLeasedFileURL(
            for: firstKey,
            projectedSize: 3,
            materialize: { destination in
                try Data("111".utf8).write(to: destination)
            },
            operation: { firstURL in
                await #expect(
                    throws: WorkspaceChangesBaseContentCache.Error.entryExceedsByteBudget
                ) {
                    try await cache.withLeasedFileURL(
                        for: secondKey,
                        projectedSize: 3,
                        materialize: { _ in
                            try Data("should-not-run".utf8).write(
                                to: rejectedMaterialization
                            )
                        },
                        operation: { $0 }
                    )
                }
                #expect(!FileManager.default.fileExists(
                    atPath: rejectedMaterialization.path
                ))
                #expect(FileManager.default.fileExists(atPath: firstURL.path))
                let contents = try Data(contentsOf: firstURL)
                #expect(contents == Data("111".utf8))
                return firstURL
            }
        )

        #expect(FileManager.default.fileExists(atPath: survivingURL.path))
        let admittedURL = try await cache.withLeasedFileURL(
            for: secondKey,
            projectedSize: 3,
            materialize: { destination in
                try Data("222".utf8).write(to: destination)
            },
            operation: { $0 }
        )
        #expect(!FileManager.default.fileExists(atPath: survivingURL.path))
        #expect(FileManager.default.fileExists(atPath: admittedURL.path))
    }
}
