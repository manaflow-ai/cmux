import Darwin
import Foundation
import Testing

@testable import CmuxGit

@Suite struct WorktreeIncludeMetadataAndStagingTests {
    @Test func copiedFilePreservesQuarantineMetadata() throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = source.appendingPathComponent("downloaded-tool")
        let destinationFile = destination.appendingPathComponent("downloaded-tool")
        let quarantine = Data("0081;665f1820;cmux;https://example.invalid/tool".utf8)
        try "payload\n".write(to: sourceFile, atomically: true, encoding: .utf8)
        try setExtendedAttribute(
            named: "com.apple.quarantine",
            value: quarantine,
            at: sourceFile
        )

        let diagnostics = WorktreeIncludeCopyService(
            fileManager: .default,
            limits: WorktreeIncludeCopyLimits(
                maximumItemCount: 10,
                maximumByteCount: 1_024,
                freeSpaceReserve: 0
            ),
            availableCapacity: { _ in 1_024 }
        ).copy(relativePaths: ["downloaded-tool"], from: source, to: destination)

        #expect(diagnostics.isEmpty)
        #expect(
            try extendedAttribute(named: "com.apple.quarantine", at: destinationFile)
                == quarantine
        )
    }

    @Test func extendedAttributeBytesCountTowardCopyLimit() throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = source.appendingPathComponent("metadata-heavy")
        #expect(FileManager.default.createFile(atPath: sourceFile.path, contents: Data()))
        try setExtendedAttribute(
            named: "com.cmux.worktreeinclude.large",
            value: Data(repeating: 0x41, count: 2_048),
            at: sourceFile
        )

        let diagnostics = WorktreeIncludeCopyService(
            fileManager: .default,
            limits: WorktreeIncludeCopyLimits(
                maximumItemCount: 10,
                maximumByteCount: 1_024,
                freeSpaceReserve: 0
            ),
            availableCapacity: { _ in 4_096 }
        ).copy(relativePaths: ["metadata-heavy"], from: source, to: destination)

        #expect(diagnostics.contains { $0.localizedCaseInsensitiveContains("copy limit") })
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("metadata-heavy").path
        ))
    }

    @Test func directoryCandidateIsNotVisibleUntilItsContentsAreComplete() throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceCache = source.appendingPathComponent("cache", isDirectory: true)
        let destinationCache = destination.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceCache, withIntermediateDirectories: true)
        try "payload\n".write(
            to: sourceCache.appendingPathComponent("payload"),
            atomically: true,
            encoding: .utf8
        )
        let observer = DestinationCandidateVisibilityObserver(candidate: destinationCache)

        let diagnostics = WorktreeIncludeCopyService(
            fileManager: .default,
            limits: WorktreeIncludeCopyLimits(
                maximumItemCount: 10,
                maximumByteCount: 1_024,
                freeSpaceReserve: 0
            ),
            availableCapacity: { _ in 4_096 },
            destinationFileCreated: observer.observe
        ).copy(relativePaths: ["cache"], from: source, to: destination)

        #expect(diagnostics.isEmpty)
        #expect(observer.candidateVisibility == [false])
        #expect(try String(
            contentsOf: destinationCache.appendingPathComponent("payload"),
            encoding: .utf8
        ) == "payload\n")
    }

    @Test func cancellationStopsDirectoryMetadataTraversalBeforeInstall() async throws {
        let (root, source, destination) = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceCache = source.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceCache, withIntermediateDirectories: true)

        let copy = Task {
            WorktreeIncludeCopyService(
                fileManager: .default,
                limits: WorktreeIncludeCopyLimits(
                    maximumItemCount: 10,
                    maximumByteCount: 1_024,
                    freeSpaceReserve: 0
                ),
                availableCapacity: { _ in 4_096 },
                sourceItemInspected: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            ).copy(relativePaths: ["cache"], from: source, to: destination)
        }

        let diagnostics = await copy.value

        #expect(diagnostics.contains { $0.localizedCaseInsensitiveContains("cancel") })
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("cache").path
        ))
    }

    private func makeRepositoryFixture() throws -> (root: URL, source: URL, destination: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-worktreeinclude-metadata-\(UUID().uuidString)",
            isDirectory: true
        )
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return (root, source, destination)
    }

    private func setExtendedAttribute(named name: String, value: Data, at url: URL) throws {
        let result = value.withUnsafeBytes { valueBytes in
            url.path.withCString { pathPointer in
                name.withCString { namePointer in
                    Darwin.setxattr(
                        pathPointer,
                        namePointer,
                        valueBytes.baseAddress,
                        valueBytes.count,
                        0,
                        0
                    )
                }
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func extendedAttribute(named name: String, at url: URL) throws -> Data {
        let size = url.path.withCString { pathPointer in
            name.withCString { namePointer in
                Darwin.getxattr(pathPointer, namePointer, nil, 0, 0, 0)
            }
        }
        guard size >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var value = Data(count: size)
        let count = value.withUnsafeMutableBytes { valueBytes in
            url.path.withCString { pathPointer in
                name.withCString { namePointer in
                    Darwin.getxattr(
                        pathPointer,
                        namePointer,
                        valueBytes.baseAddress,
                        valueBytes.count,
                        0,
                        0
                    )
                }
            }
        }
        guard count == size else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return value
    }
}
