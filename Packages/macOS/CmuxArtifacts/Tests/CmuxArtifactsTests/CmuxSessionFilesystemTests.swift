import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("cmux session filesystem")
struct CmuxSessionFilesystemTests {
    @Test("Artifact capture writes beneath the agent session root")
    func capturesIntoSessionArtifactsDirectory() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = try ArtifactTestSupport.write(
            "# Plan",
            named: "outside/plan.md",
            under: root
        )

        let outcome = try await LocalArtifactRepository().importFile(
            sourceURL: source,
            context: ArtifactCaptureContext(
                projectRoot: root,
                workspaceID: "workspace:42",
                workspaceTitle: "API Work",
                sessionID: "session:99",
                agentName: "Codex"
            ),
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let record = try #require(outcome.record)
        let sessionName = try #require(record.relativePath.split(separator: "/").first)
        #expect(sessionName.hasPrefix("codex-session-99-"))
        #expect(record.relativePath == "\(sessionName)/artifacts/plan.md")
        let sessionRoot = root.appendingPathComponent(".cmux/\(sessionName)")
        #expect(FileManager.default.fileExists(
            atPath: sessionRoot.appendingPathComponent("artifacts/plan.md").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: sessionRoot.appendingPathComponent("_session.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: sessionRoot.appendingPathComponent("_workspace.json").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".cmux/artifacts").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                ".cmux/.metadata/provenance/\(record.digest).json"
            ).path
        ))
    }

    @Test("The live tree includes notes beside artifacts under one session")
    func scansUnifiedSessionContents() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let sessionRoot = root.appendingPathComponent(".cmux/codex-session-one")
        _ = try ArtifactTestSupport.write(
            "artifact",
            named: "artifacts/report.txt",
            under: sessionRoot
        )
        _ = try ArtifactTestSupport.write(
            "# Notes",
            named: "notes/plan.md",
            under: sessionRoot
        )

        let snapshot = try await LocalArtifactRepository().snapshot(projectRoot: root)
        let paths = snapshot.nodes.flattenedArtifactNodes().map(\.relativePath)

        #expect(snapshot.filesystemRoot == root.appendingPathComponent(".cmux"))
        #expect(paths.contains("codex-session-one/artifacts/report.txt"))
        #expect(paths.contains("codex-session-one/notes/plan.md"))
    }

    @Test("Prompt-ready cmux references resolve against the unified filesystem")
    func resolvesCmuxReference() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        _ = try ArtifactTestSupport.write(
            "artifact",
            named: ".cmux/session/artifacts/report.txt",
            under: root
        )

        let node = try await LocalArtifactRepository().resolve(
            projectRoot: root,
            name: ".cmux/session/artifacts/report.txt"
        )

        #expect(node.relativePath == "session/artifacts/report.txt")
    }

    @Test("Moving a session keeps it as the destination for later captures")
    func reusesMovedSessionRoot() async throws {
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
            provenance: .manual,
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
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: .now
        )

        #expect(second.record?.relativePath == "organized/renamed-session/artifacts/second.md")
    }

    @Test("Similar pending session identifiers never share a capture directory")
    func separatesPendingSessionIdentifiersWithTheSameReadablePrefix() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        let firstSource = try ArtifactTestSupport.write("first", named: "outside/first.md", under: root)
        let secondSource = try ArtifactTestSupport.write("second", named: "outside/second.md", under: root)

        let first = try await repository.importFile(
            sourceURL: firstSource,
            context: ArtifactCaptureContext(
                projectRoot: root,
                sessionID: "pending-claude-a1111111-1111-1111-1111-111111111111",
                agentName: "claude"
            ),
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let second = try await repository.importFile(
            sourceURL: secondSource,
            context: ArtifactCaptureContext(
                projectRoot: root,
                sessionID: "pending-claude-a2222222-2222-2222-2222-222222222222",
                agentName: "claude"
            ),
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 2)
        )

        let firstRoot = try #require(first.record?.relativePath.split(separator: "/").first)
        let secondRoot = try #require(second.record?.relativePath.split(separator: "/").first)
        #expect(firstRoot != secondRoot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let firstMarker = try decoder.decode(
            ArtifactSessionMarker.self,
            from: Data(contentsOf: root.appendingPathComponent(".cmux/\(firstRoot)/_session.json"))
        )
        let secondMarker = try decoder.decode(
            ArtifactSessionMarker.self,
            from: Data(contentsOf: root.appendingPathComponent(".cmux/\(secondRoot)/_session.json"))
        )
        #expect(firstMarker.sessionID == "pending-claude-a1111111-1111-1111-1111-111111111111")
        #expect(secondMarker.sessionID == "pending-claude-a2222222-2222-2222-2222-222222222222")
    }

    @Test("Short session identifiers that normalize alike never share a capture directory")
    func separatesShortSessionIdentifiersWithTheSameNormalizedValue() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        let firstSource = try ArtifactTestSupport.write("first", named: "outside/first.txt", under: root)
        let secondSource = try ArtifactTestSupport.write("second", named: "outside/second.txt", under: root)

        let first = try await repository.importFile(
            sourceURL: firstSource,
            context: ArtifactCaptureContext(
                projectRoot: root,
                sessionID: "Ab:C",
                agentName: "codex"
            ),
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let second = try await repository.importFile(
            sourceURL: secondSource,
            context: ArtifactCaptureContext(
                projectRoot: root,
                sessionID: "ab-c",
                agentName: "codex"
            ),
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 2)
        )

        let firstRoot = try #require(first.record?.relativePath.split(separator: "/").first)
        let secondRoot = try #require(second.record?.relativePath.split(separator: "/").first)
        #expect(firstRoot != secondRoot)
    }

    @Test("Capture fails closed when moved-session discovery exceeds its node budget")
    func rejectsIncompleteMovedSessionDiscovery() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let paths = ArtifactStorePaths(projectRoot: root)
        let movedRoot = paths.filesystemRoot.appendingPathComponent("organized/session", isDirectory: true)
        try FileManager.default.createDirectory(at: movedRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(
            ArtifactSessionMarker(
                sessionID: "session-beyond-budget",
                agentName: "codex",
                createdAt: Date(timeIntervalSince1970: 1)
            )
        ).write(to: movedRoot.appendingPathComponent(ArtifactPathResolver.sessionMarkerName))
        let source = try ArtifactTestSupport.write("new", named: "outside/new.md", under: root)
        let repository = LocalArtifactRepository(nodeBudget: 1)

        await #expect(throws: ArtifactStoreError.scanIncomplete(paths.filesystemRoot.path)) {
            try await repository.importFile(
                sourceURL: source,
                context: ArtifactCaptureContext(
                    projectRoot: root,
                    sessionID: "session-beyond-budget",
                    agentName: "codex"
                ),
                provenance: .manual,
                configuration: .defaultValue,
                capturedAt: Date(timeIntervalSince1970: 2)
            )
        }
    }

    @Test("Git excludes every session content kind without hiding project config")
    func installsSessionFilesystemGitExcludes() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        #expect(try ArtifactTestSupport.runGit(["init", "--quiet", root.path]) == 0)

        _ = try await LocalArtifactRepository().snapshot(projectRoot: root)

        let exclude = try String(
            contentsOf: root.appendingPathComponent(".git/info/exclude"),
            encoding: .utf8
        )
        let lines = Set(exclude.split(separator: "\n").map(String.init))
        #expect(lines.contains(".cmux/**/artifacts/"))
        #expect(lines.contains(".cmux/**/notes/"))
        #expect(lines.contains(".cmux/**/_session.json"))
        #expect(lines.contains(".cmux/**/_workspace.json"))
        #expect(lines.contains(".cmux/.metadata/"))
        #expect(!lines.contains(".cmux/"))
    }
}
