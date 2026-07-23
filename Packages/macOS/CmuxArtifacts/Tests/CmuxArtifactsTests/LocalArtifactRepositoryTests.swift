import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Local artifact repository")
struct LocalArtifactRepositoryTests {
    @Test("Import groups files and records hidden provenance")
    func importsWithGroupingAndProvenance() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        #expect(try runGit(["init", "--quiet", root.path]) == 0)
        let source = try ArtifactTestSupport.write("# Plan", named: "plan.md", under: root.appendingPathComponent("source"))
        let repository = LocalArtifactRepository()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        let outcome = try await repository.importFile(
            sourceURL: source,
            context: ArtifactCaptureContext(
                projectRoot: root,
                workspaceID: "workspace:42",
                workspaceTitle: "API Work",
                sessionID: "session:99",
                agentName: "Codex"
            ),
            provenance: .created,
            configuration: .defaultValue,
            capturedAt: timestamp
        )

        guard case .copied(let record) = outcome else {
            Issue.record("Expected a new copy")
            return
        }
        #expect(record.relativePath.hasSuffix("/artifacts/plan.md"))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".cmux/\(record.relativePath)").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".cmux/.metadata/provenance/\(record.digest).json").path
        ))
        let snapshot = try await repository.snapshot(projectRoot: root)
        let sessionRoot = try #require(record.relativePath.split(separator: "/").first)
        #expect(snapshot.nodes.map(\.name) == [String(sessionRoot)])

        let exclude = try String(
            contentsOf: root.appendingPathComponent(".git/info/exclude"),
            encoding: .utf8
        )
        let excludeLines = Set(exclude.split(separator: "\n").map(String.init))
        #expect(excludeLines.isSuperset(of: Set(ArtifactGitIgnoreManager.ignoreEntries)))
        _ = try await repository.snapshot(projectRoot: root)
        let secondExclude = try String(
            contentsOf: root.appendingPathComponent(".git/info/exclude"),
            encoding: .utf8
        )
        #expect(secondExclude == exclude)
    }

    @Test("Content digest deduplicates after a user move")
    func deduplicatesAfterMove() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = try ArtifactTestSupport.write("same bytes", named: "result.txt", under: root.appendingPathComponent("outside"))
        let repository = LocalArtifactRepository()
        let context = ArtifactCaptureContext(projectRoot: root, workspaceID: "one", sessionID: "two")
        let first = try await repository.importFile(
            sourceURL: source,
            context: context,
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: .now
        )
        let original = try #require(first.record)
        let originalURL = root.appendingPathComponent(".cmux/\(original.relativePath)")
        let movedURL = root.appendingPathComponent(".cmux/organized/final.txt")
        try FileManager.default.createDirectory(at: movedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        let second = try await repository.importFile(
            sourceURL: source,
            context: context,
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: .now
        )

        guard case .deduplicated(let record) = second else {
            Issue.record("Expected content deduplication")
            return
        }
        #expect(record.relativePath == "organized/final.txt")
    }

    @Test("Moved-file deduplication is independent of the sidebar node budget")
    func deduplicatesMovedFileBeyondSidebarBudget() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = try ArtifactTestSupport.write(
            "same bytes",
            named: "result.txt",
            under: root.appendingPathComponent("outside")
        )
        let repository = LocalArtifactRepository(nodeBudget: 1)
        let context = ArtifactCaptureContext(
            projectRoot: root,
            workspaceID: "one",
            sessionID: "two"
        )
        let first = try await repository.importFile(
            sourceURL: source,
            context: context,
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: .now
        )
        let original = try #require(first.record)
        let originalURL = root.appendingPathComponent(".cmux/\(original.relativePath)")
        let movedURL = root.appendingPathComponent(".cmux/organized/final.txt")
        try FileManager.default.createDirectory(
            at: movedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        let second = try await repository.importFile(
            sourceURL: source,
            context: context,
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: .now
        )

        guard case .deduplicated(let record) = second else {
            Issue.record("Expected content deduplication beyond the sidebar budget")
            return
        }
        #expect(record.relativePath == "organized/final.txt")
    }

    @Test("Content deduplication includes unmanaged ordinary store files")
    func deduplicatesUnmanagedStoreFile() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = try ArtifactTestSupport.write(
            "same bytes",
            named: "result.txt",
            under: root.appendingPathComponent("outside")
        )
        _ = try ArtifactTestSupport.write(
            "same bytes",
            named: "organized/final.txt",
            under: root.appendingPathComponent(".cmux")
        )
        let repository = LocalArtifactRepository()
        let context = ArtifactCaptureContext(projectRoot: root, workspaceID: "one", sessionID: "two")

        let outcome = try await repository.importFile(
            sourceURL: source,
            context: context,
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: .now
        )

        guard case .deduplicated(let record) = outcome else {
            Issue.record("Expected unmanaged ordinary file content to deduplicate")
            return
        }
        #expect(record.relativePath == "organized/final.txt")
    }

    @Test("A moved session folder remains the target for later captures")
    func reusesMovedSessionFolder() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        let context = ArtifactCaptureContext(
            projectRoot: root,
            workspaceID: "workspace-one",
            sessionID: "session-one",
            agentName: "codex"
        )
        let firstSource = try ArtifactTestSupport.write("first", named: "first.md", under: root)
        let first = try await repository.importFile(
            sourceURL: firstSource,
            context: context,
            provenance: .created,
            configuration: .defaultValue,
            capturedAt: .now
        )
        let firstRecord = try #require(first.record)
        let originalSession = root.appendingPathComponent(".cmux/\(firstRecord.relativePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let movedSession = root.appendingPathComponent(".cmux/organized/renamed-session")
        try FileManager.default.createDirectory(
            at: movedSession.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: originalSession, to: movedSession)
        let secondSource = try ArtifactTestSupport.write("second", named: "second.md", under: root)

        let second = try await repository.importFile(
            sourceURL: secondSource,
            context: context,
            provenance: .created,
            configuration: .defaultValue,
            capturedAt: .now
        )

        #expect(second.record?.relativePath == "organized/renamed-session/artifacts/second.md")
    }

    @Test("A moved workspace-only session remains the capture destination")
    func reusesMovedWorkspaceOnlySession() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        let firstContext = ArtifactCaptureContext(
            projectRoot: root,
            workspaceID: "workspace-one",
            agentName: "codex"
        )
        let firstSource = try ArtifactTestSupport.write("first", named: "first.md", under: root)
        let first = try await repository.importFile(
            sourceURL: firstSource,
            context: firstContext,
            provenance: .created,
            configuration: .defaultValue,
            capturedAt: .now
        )
        let firstRecord = try #require(first.record)
        let originalSession = root.appendingPathComponent(".cmux/\(firstRecord.relativePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let movedSession = root.appendingPathComponent(".cmux/my-organized-workspace")
        try FileManager.default.moveItem(at: originalSession, to: movedSession)
        let secondSource = try ArtifactTestSupport.write("second", named: "second.md", under: root)

        let second = try await repository.importFile(
            sourceURL: secondSource,
            context: ArtifactCaptureContext(
                projectRoot: root,
                workspaceID: "workspace-one",
                agentName: "codex"
            ),
            provenance: .created,
            configuration: .defaultValue,
            capturedAt: .now
        )

        #expect(second.record?.relativePath == "my-organized-workspace/artifacts/second.md")
    }

    @Test("A nested cmux project is excluded by its enclosing Git repository")
    func ignoresNestedProjectStore() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let project = root.appendingPathComponent("nested/project")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".cmux"),
            withIntermediateDirectories: true
        )

        _ = try await LocalArtifactRepository().snapshot(projectRoot: project)

        let exclude = try String(
            contentsOf: root.appendingPathComponent(".git/info/exclude"),
            encoding: .utf8
        )
        #expect(exclude == ArtifactGitIgnoreManager.ignoreEntries
            .map { "nested/project/\($0)" }
            .joined(separator: "\n") + "\n")
    }

    @Test("A linked worktree uses the common Git exclude file")
    func ignoresStoreFromLinkedWorktree() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let commonGitDirectory = root.appendingPathComponent("repository/.git")
        let worktreeGitDirectory = commonGitDirectory.appendingPathComponent("worktrees/feature")
        let worktree = root.appendingPathComponent("feature")
        try FileManager.default.createDirectory(at: worktreeGitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "../..\n".write(
            to: worktreeGitDirectory.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )
        try "\(worktree.appendingPathComponent(".git").path)\n".write(
            to: worktreeGitDirectory.appendingPathComponent("gitdir"),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: \(worktreeGitDirectory.path)\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        _ = try await LocalArtifactRepository().snapshot(projectRoot: worktree)

        let exclude = try String(
            contentsOf: commonGitDirectory.appendingPathComponent("info/exclude"),
            encoding: .utf8
        )
        #expect(exclude == ArtifactGitIgnoreManager.ignoreEntries.joined(separator: "\n") + "\n")
        #expect(!FileManager.default.fileExists(
            atPath: worktreeGitDirectory.appendingPathComponent("info/exclude").path
        ))
    }

    @Test("Search combines fuzzy names with bounded text content")
    func searchesNamesAndContents() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let artifactRoot = root.appendingPathComponent(".cmux/session/artifacts")
        _ = try ArtifactTestSupport.write("release checklist", named: "launch-plan.md", under: artifactRoot)
        _ = try ArtifactTestSupport.write("the hidden needle is here", named: "notes.txt", under: artifactRoot)
        let repository = LocalArtifactRepository()

        let filenameResults = try await repository.search(projectRoot: root, query: "lnchpln")
        #expect(filenameResults.first?.node.name == "launch-plan.md")
        let contentResults = try await repository.search(projectRoot: root, query: "needle")
        #expect(contentResults.first?.node.name == "notes.txt")
        #expect(contentResults.first?.matchedContent == true)
        #expect(contentResults.first?.snippet == "the hidden needle is here")
    }

    @Test("Partial configuration inherits conservative defaults")
    func loadsPartialConfiguration() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        _ = try ArtifactTestSupport.write(
            #"{"automaticCaptureEnabled":false,"maximumFileBytes":100}"#,
            named: "artifacts.json",
            under: root.appendingPathComponent(".cmux")
        )
        let configuration = await LocalArtifactRepository().configuration(projectRoot: root)
        #expect(configuration.automaticCaptureEnabled == false)
        #expect(configuration.maximumFileBytes == 100)
        #expect(configuration.maximumTextFileBytes == 100)
        #expect(configuration.maximumTranscriptScanBytes == ArtifactCaptureConfiguration.defaultValue.maximumTranscriptScanBytes)
        #expect(configuration.allowedExtensions == ArtifactCaptureConfiguration.defaultValue.allowedExtensions)
    }

    @Test("Import rejects files larger than the configured text limit")
    func rejectsOversizedTextFile() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = try ArtifactTestSupport.write(
            "five!",
            named: "oversized.txt",
            under: root.appendingPathComponent("outside")
        )
        var configuration = ArtifactCaptureConfiguration.defaultValue
        configuration.maximumTextFileBytes = 4

        await #expect(
            throws: ArtifactStoreError.fileTooLarge(actual: 5, limit: 4)
        ) {
            try await LocalArtifactRepository().importFile(
                sourceURL: source,
                context: ArtifactCaptureContext(projectRoot: root),
                provenance: .created,
                configuration: configuration,
                capturedAt: .now
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".cmux/session/artifacts/oversized.txt").path
        ))
        let stagingRoot = ArtifactStorePaths(projectRoot: root).importStagingRoot
        let stagingContents = try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
        #expect(stagingContents.isEmpty)
    }

    @Test("Recursive changes reflect external filesystem edits")
    func watchesExternalChanges() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        let changes = await repository.changes(projectRoot: root)

        _ = try ArtifactTestSupport.write(
            "appeared outside cmux",
            named: "external/new-file.md",
            under: root.appendingPathComponent(".cmux/session/artifacts")
        )
        let observed = await firstResult(
            operation: {
                var iterator = changes.makeAsyncIterator()
                guard await iterator.next() != nil else { return false }
                return await iterator.next() != nil
            },
            timeout: .seconds(3)
        )

        #expect(observed == true)
    }

    @Test("A symlinked cmux filesystem root is rejected without writing through it")
    func rejectsSymlinkedFilesystemRoot() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let outside = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".cmux"),
            withDestinationURL: outside
        )
        let source = try ArtifactTestSupport.write("safe", named: "safe.md", under: root)

        await #expect(throws: ArtifactStoreError.self) {
            try await LocalArtifactRepository().importFile(
                sourceURL: source,
                context: ArtifactCaptureContext(projectRoot: root),
                provenance: .manual,
                configuration: .defaultValue,
                capturedAt: .now
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("A symlinked capture group cannot redirect an import")
    func rejectsSymlinkedCaptureGroup() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let outside = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(outside) }
        let cmuxRoot = root.appendingPathComponent(".cmux")
        try FileManager.default.createDirectory(at: cmuxRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: cmuxRoot.appendingPathComponent("session"),
            withDestinationURL: outside
        )
        let source = try ArtifactTestSupport.write("safe", named: "safe.md", under: root)

        await #expect(throws: ArtifactStoreError.self) {
            try await LocalArtifactRepository().importFile(
                sourceURL: source,
                context: ArtifactCaptureContext(projectRoot: root),
                provenance: .manual,
                configuration: .defaultValue,
                capturedAt: .now
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @discardableResult
    private func runGit(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func firstResult(
        operation: @escaping @Sendable () async -> Bool,
        timeout: Duration
    ) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                // This bounded test deadline prevents a broken watcher from hanging the suite.
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
