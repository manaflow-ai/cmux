import Foundation
import Testing

@testable import CmuxGit

@Suite struct WorktreeIncludeSafetyLimitTests {
    @Test func cleanupPreservesConcurrentDestinationReplacement() throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = source.appendingPathComponent("payload")
        let destinationFile = destination.appendingPathComponent("payload")
        let displacedCopy = destination.appendingPathComponent("payload.displaced")
        try Data([0x41]).write(to: sourceFile)

        let diagnostics = WorktreeIncludeCopyService(
            fileManager: .default,
            limits: WorktreeIncludeCopyLimits(
                maximumItemCount: 10,
                maximumByteCount: 1_024,
                freeSpaceReserve: 0
            ),
            availableCapacity: { _ in 4_096 },
            destinationFileCreated: { createdFile in
                try? FileManager.default.moveItem(at: createdFile, to: displacedCopy)
                try? Data("concurrent\n".utf8).write(to: createdFile)
            },
            sourceItemInspected: { inspectedItem in
                guard inspectedItem == sourceFile,
                      let handle = try? FileHandle(forWritingTo: inspectedItem) else { return }
                try? handle.truncate(atOffset: 2_048)
                try? handle.close()
            }
        ).copy(relativePaths: ["payload"], from: source, to: destination)

        #expect(diagnostics.contains { $0.localizedCaseInsensitiveContains("copy limit") })
        #expect(try Data(contentsOf: destinationFile) == Data("concurrent\n".utf8))
    }

    @Test func capacityIsRecheckedBeforeCreatingMetadataOnlyItems() throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = source.appendingPathComponent("cache", isDirectory: true)
        let inspectionMarker = root.appendingPathComponent("source-inspected")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let diagnostics = WorktreeIncludeCopyService(
            fileManager: .default,
            limits: WorktreeIncludeCopyLimits(
                maximumItemCount: 10,
                maximumByteCount: 1_024,
                freeSpaceReserve: 512
            ),
            availableCapacity: { _ in
                FileManager.default.fileExists(atPath: inspectionMarker.path) ? 512 : 513
            },
            sourceItemInspected: { inspectedItem in
                guard inspectedItem == sourceDirectory else { return }
                _ = FileManager.default.createFile(atPath: inspectionMarker.path, contents: Data())
            }
        ).copy(relativePaths: ["cache"], from: source, to: destination)

        #expect(diagnostics.contains { $0.localizedCaseInsensitiveContains("free space") })
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("cache").path
        ))
    }

    @Test func destinationSymlinkAncestorCannotEscapeWorktree() throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = source.appendingPathComponent("linked", isDirectory: true)
        let outsideDirectory = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try "secret\n".write(
            to: sourceDirectory.appendingPathComponent("payload"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("linked"),
            withDestinationURL: outsideDirectory
        )

        let diagnostics = WorktreeIncludeCopyService(
            fileManager: .default,
            limits: WorktreeIncludeCopyLimits(
                maximumItemCount: 10,
                maximumByteCount: 1_024,
                freeSpaceReserve: 0
            ),
            availableCapacity: { _ in 1_024 }
        ).copy(relativePaths: ["linked/payload"], from: source, to: destination)

        #expect(!FileManager.default.fileExists(
            atPath: outsideDirectory.appendingPathComponent("payload").path
        ))
        #expect(!diagnostics.isEmpty)
    }

    @Test func sourceTypeChangeCannotBypassCopyBudget() throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = source.appendingPathComponent("nested", isDirectory: true)
        let sourceItem = sourceDirectory.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: sourceItem,
            withDestinationURL: sourceDirectory.appendingPathComponent("missing")
        )
        let sourceSwapper = SourceTypeSwappingWorktreeIncludeFileManager(
            sourceItem: sourceItem,
            replacementByteCount: 2_048
        )

        _ = WorktreeIncludeCopyService(
            fileManager: .default,
            limits: WorktreeIncludeCopyLimits(
                maximumItemCount: 10,
                maximumByteCount: 1_024,
                freeSpaceReserve: 0
            ),
            availableCapacity: { _ in 1_024 },
            sourceItemInspected: sourceSwapper.swapIfMatching
        ).copy(relativePaths: ["nested/payload"], from: source, to: destination)

        let copied = destination.appendingPathComponent("nested/payload")
        let copiedValues = try? copied.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        #expect(copiedValues?.isRegularFile != true || (copiedValues?.fileSize ?? 0) <= 1_024)
    }

    @Test func copiedCredentialFileIsPrivateFromCreation() throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = source.appendingPathComponent(".env")
        try "secret\n".write(to: sourceFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sourceFile.path
        )
        let observer = DestinationFileCreationPermissionObserver()

        let diagnostics = WorktreeIncludeCopyService(
            fileManager: .default,
            limits: WorktreeIncludeCopyLimits(
                maximumItemCount: 10,
                maximumByteCount: 1_024,
                freeSpaceReserve: 0
            ),
            availableCapacity: { _ in 1_024 },
            destinationFileCreated: observer.observe
        ).copy(relativePaths: [".env"], from: source, to: destination)

        let finalAttributes = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent(".env").path
        )
        #expect(diagnostics.isEmpty)
        #expect(observer.observedPermissions == [0o600])
        #expect(finalAttributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func createdParentDirectoriesCountTowardItemLimit() throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let relativePath = "one/two/three/payload"
        let sourceFile = source.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: sourceFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "value\n".write(to: sourceFile, atomically: true, encoding: .utf8)

        let diagnostics = WorktreeIncludeCopyService(
            fileManager: .default,
            limits: WorktreeIncludeCopyLimits(
                maximumItemCount: 3,
                maximumByteCount: 1_024,
                freeSpaceReserve: 0
            ),
            availableCapacity: { _ in 1_024 }
        ).copy(relativePaths: [relativePath], from: source, to: destination)

        #expect(diagnostics.contains { $0.localizedCaseInsensitiveContains("copy limit") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func unavailableCapacityFailsClosed() throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = source.appendingPathComponent("payload")
        try "value\n".write(to: sourceFile, atomically: true, encoding: .utf8)

        let diagnostics = WorktreeIncludeCopyService(
            fileManager: .default,
            limits: WorktreeIncludeCopyLimits(
                maximumItemCount: 10,
                maximumByteCount: 1_024,
                freeSpaceReserve: 0
            ),
            availableCapacity: { _ in nil }
        ).copy(relativePaths: ["payload"], from: source, to: destination)

        #expect(diagnostics.contains { $0.localizedCaseInsensitiveContains("available capacity") })
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("payload").path))
    }

    @Test func copiedDirectoryPreservesRestrictivePermissions() async throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = source.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        try "token\n".write(
            to: credentials.appendingPathComponent("api-key"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: credentials.path
        )
        try "credentials/\n".write(
            to: source.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "credentials/\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = await WorktreeIncludeSyncService().sync(from: source, to: destination)
        let copiedAttributes = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent("credentials").path
        )

        #expect(diagnostics.isEmpty)
        #expect(copiedAttributes[.posixPermissions] as? Int == 0o700)
    }

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

    @Test func fileGrowthDuringCopyCannotBypassBudget() async throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = source.appendingPathComponent("cache", isDirectory: true)
        let growingFile = cache.appendingPathComponent("growing.bin")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: growingFile.path, contents: Data([0])))
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
        let fileManager = GrowingWorktreeIncludeFileManager(
            targetDirectory: cache,
            fileToGrow: growingFile,
            grownByteCount: 2_048
        )

        let diagnostics = await WorktreeIncludeSyncService(
            fileManager: fileManager,
            copyLimits: WorktreeIncludeCopyLimits(
                maximumItemCount: 500_000,
                maximumByteCount: 4_096,
                freeSpaceReserve: 0
            ),
            availableCapacity: { _ in 1_024 }
        ).sync(
            from: source,
            to: destination
        )

        #expect(diagnostics.contains { $0.localizedCaseInsensitiveContains("lacks sufficient free space") })
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("cache").path))
    }

    @Test func undecodableGitOutputAbortsWithDiagnostic() async throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try ".env\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = await WorktreeIncludeSyncService(
            commandRunner: UndecodableWorktreeIncludeCommandRunner()
        ).sync(from: source, to: destination)

        #expect(diagnostics.contains { $0.contains("UTF-8") })
    }

    @Test func cancellationStopsBeforeGitMatching() async throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "node_modules/\n.env\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        let runner = CandidateFilteringCommandRunner()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await WorktreeIncludeSyncService(commandRunner: runner).sync(
                from: source,
                to: destination
            )
        }

        let diagnostics = await task.value

        #expect(diagnostics.contains { $0.localizedCaseInsensitiveContains("cancel") })
        #expect(await runner.invocations().isEmpty)
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
