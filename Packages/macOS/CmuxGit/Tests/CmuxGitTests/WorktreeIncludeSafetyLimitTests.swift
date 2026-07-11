import Foundation
import Testing

@testable import CmuxGit

@Suite struct WorktreeIncludeSafetyLimitTests {
    @Test func collapsedDirectoryOverCopyBudgetIsNotCopied() async throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = source.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try "cache/\n".write(
            to: source.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "cache/\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        let sparseFile = cache.appendingPathComponent("oversized.bin")
        #expect(FileManager.default.createFile(atPath: sparseFile.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: sparseFile)
        try handle.truncate(atOffset: 51 * 1024 * 1024 * 1024)
        try handle.close()

        let diagnostics = await WorktreeIncludeSyncService().sync(from: source, to: destination)

        #expect(diagnostics.contains { $0.localizedCaseInsensitiveContains("copy limit") })
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("cache").path))
    }

    @Test func failedStandardIgnoreBatchStopsTheStage() async throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "cache*/\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        let runner = FailingWorktreeIncludeCommandRunner()

        let diagnostics = await WorktreeIncludeSyncService(commandRunner: runner).sync(
            from: source,
            to: destination
        )

        #expect(diagnostics.contains { $0.localizedCaseInsensitiveContains("timed out") })
        #expect(await runner.standardIgnoreCallCount() == 1)
    }

    @Test func duplicatePassResultsCountOnceTowardMatchLimit() async throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = DuplicateWorktreeIncludeCommandRunner()
        try "cache/\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("cache", isDirectory: true),
            withIntermediateDirectories: true
        )
        for index in 0..<5_001 {
            #expect(FileManager.default.createFile(
                atPath: source.appendingPathComponent("cache/file-\(index)").path,
                contents: Data()
            ))
        }

        let diagnostics = await WorktreeIncludeSyncService(commandRunner: runner).sync(
            from: source,
            to: destination
        )

        #expect(!diagnostics.contains { $0.localizedCaseInsensitiveContains("too many paths") })
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("cache/file-5000").path
        ))
    }

    @Test func tooManyCandidatePathsProduceDiagnosticWithoutCopying() async throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "cache*/\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = await WorktreeIncludeSyncService(
            commandRunner: OversizedWorktreeCandidateCommandRunner()
        ).sync(from: source, to: destination)

        #expect(diagnostics.contains { $0.localizedCaseInsensitiveContains("too many paths") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func newlineInCollapsedDirectoryCannotSelectUnrelatedIgnoredPath() async throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        try "cache*/\nunrelated/\n".write(
            to: source.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "cache*/\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )

        let newlineDirectory = source.appendingPathComponent("cache\nunrelated", isDirectory: true)
        let unrelatedDirectory = source.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: newlineDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)
        try "selected".write(
            to: newlineDirectory.appendingPathComponent("selected.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "unrelated".write(
            to: unrelatedDirectory.appendingPathComponent("unrelated.txt"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = await WorktreeIncludeSyncService().sync(from: source, to: destination)

        #expect(diagnostics.contains { $0.localizedCaseInsensitiveContains("newline") })
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("cache\nunrelated").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("unrelated").path
        ))
    }

    private func makeRepositoryFixture() throws -> (root: URL, source: URL, destination: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-worktreeinclude-safety-\(UUID().uuidString)",
            isDirectory: true
        )
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try runGit(["init", "--quiet"], in: source)
        return (root, source, destination)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
