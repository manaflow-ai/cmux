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
            ["diff", "-M", "--name-status", "-z", "HEAD", "--"]:
                FakeWorkspaceChangesGitRunner.result("M\0large.bin\0"),
            ["diff", "-M", "--numstat", "-z", "HEAD", "--"]:
                FakeWorkspaceChangesGitRunner.result("-\t-\tlarge.bin\0"),
            ["ls-files", "--others", "--exclude-standard", "-z"]:
                FakeWorkspaceChangesGitRunner.result(),
            ["cat-file", "-s", "\(baseOID):large.bin"]:
                FakeWorkspaceChangesGitRunner.result("\(fileSize)\n"),
            ["show", "\(baseOID):large.bin"]:
                WorkspaceChangesGitResult(output: payload, exitCode: 0),
        ]
        let runner = FakeWorkspaceChangesGitRunner(
            results: results,
            beforeRun: { arguments, _ in
                guard arguments.first == "rev-parse" || arguments.first == "cat-file" else {
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
        #expect(invocationCount(["cat-file", "-s", "\(baseOID):large.bin"]) == 1)
    }
}
