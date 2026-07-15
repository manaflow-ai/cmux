import Foundation
import Testing

@testable import CmuxGit

@Suite struct WorktreeIncludeFinalSafetyTests {
    @Test func collapsedAncestorCannotCopyReservedDescendant() async throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let generated = source.appendingPathComponent("config/generated", isDirectory: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try "config/\n".write(
            to: source.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "config/\n".write(
            to: source.appendingPathComponent(".worktreeinclude"),
            atomically: true,
            encoding: .utf8
        )
        try "reserved\n".write(
            to: generated.appendingPathComponent("payload"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = await WorktreeIncludeSyncService().sync(
            from: source,
            to: destination,
            excludingRelativePaths: ["config/generated"]
        )

        #expect(diagnostics.contains { $0.localizedCaseInsensitiveContains("reserved") })
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("config/generated/payload").path
        ))
    }

    @Test func sourceSymlinkAncestorSwapCannotEscapeRepository() throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = source.appendingPathComponent("nested", isDirectory: true)
        let sourceFile = sourceDirectory.appendingPathComponent("payload")
        let displacedDirectory = source.appendingPathComponent("nested-original", isDirectory: true)
        let outsideDirectory = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try Data("inside\n".utf8).write(to: sourceFile)
        try Data("outside-secret\n".utf8).write(
            to: outsideDirectory.appendingPathComponent("payload")
        )

        let diagnostics = WorktreeIncludeCopyService(
            fileManager: .default,
            limits: WorktreeIncludeCopyLimits(
                maximumItemCount: 10,
                maximumByteCount: 1_024,
                freeSpaceReserve: 0
            ),
            availableCapacity: { _ in 1_024 },
            sourceItemInspected: { inspectedItem in
                guard inspectedItem == sourceFile else { return }
                try? FileManager.default.moveItem(at: sourceDirectory, to: displacedDirectory)
                try? FileManager.default.createSymbolicLink(
                    at: sourceDirectory,
                    withDestinationURL: outsideDirectory
                )
            }
        ).copy(relativePaths: ["nested/payload"], from: source, to: destination)

        let copiedFile = destination.appendingPathComponent("nested/payload")
        let copiedData = try? Data(contentsOf: copiedFile)
        #expect(copiedData != Data("outside-secret\n".utf8))
        #expect(!diagnostics.isEmpty)
    }

    @Test func symlinkedSourceRootStillCopiesWithinResolvedCheckout() throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceLink = root.appendingPathComponent("source-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
        try "inside\n".write(
            to: source.appendingPathComponent("payload"),
            atomically: true,
            encoding: .utf8
        )

        let diagnostics = WorktreeIncludeCopyService(
            fileManager: .default,
            limits: WorktreeIncludeCopyLimits(
                maximumItemCount: 10,
                maximumByteCount: 1_024,
                freeSpaceReserve: 0
            ),
            availableCapacity: { _ in 4_096 }
        ).copy(relativePaths: ["payload"], from: sourceLink, to: destination)

        #expect(diagnostics.isEmpty)
        #expect(try String(
            contentsOf: destination.appendingPathComponent("payload"),
            encoding: .utf8
        ) == "inside\n")
    }

    private func makeRepositoryFixture() throws -> (root: URL, source: URL, destination: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-worktreeinclude-final-safety-\(UUID().uuidString)",
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
