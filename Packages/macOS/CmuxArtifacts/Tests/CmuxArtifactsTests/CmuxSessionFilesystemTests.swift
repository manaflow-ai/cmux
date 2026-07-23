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
        #expect(record.relativePath == "codex-session-99/artifacts/plan.md")
        let sessionRoot = root.appendingPathComponent(".cmux/codex-session-99")
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
