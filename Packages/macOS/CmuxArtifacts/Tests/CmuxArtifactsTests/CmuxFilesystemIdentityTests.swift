import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("cmux filesystem identity")
struct CmuxFilesystemIdentityTests {
    @Test("Note operations ignore Markdown outside a marked session Notes root")
    func noteOperationsStayInsideMarkedNotesRoot() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        let context = ArtifactCaptureContext(
            projectRoot: root,
            sessionID: "session:notes-boundary",
            agentName: "codex"
        )
        let note = try await repository.writeNote(
            name: "plan",
            text: "real note",
            mode: .replace,
            context: context
        )
        let sessionRoot = URL(fileURLWithPath: note.absolutePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let artifact = try ArtifactTestSupport.write(
            "artifact markdown",
            named: "artifacts/notes/report.md",
            under: sessionRoot
        )

        let listed = try await repository.listNotes(projectRoot: root)
        #expect(listed.map(\.relativePath) == [note.relativePath])
        await #expect(throws: CmuxNoteStoreError.noteNotFound("report")) {
            _ = try await repository.readNote(projectRoot: root, name: "report")
        }
        await #expect(throws: CmuxNoteStoreError.noteNotFound("report")) {
            try await repository.deleteNote(projectRoot: root, name: "report")
        }
        #expect(FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test("Capture rejects duplicate session identity markers")
    func captureRejectsDuplicateSessionMarkers() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        let context = ArtifactCaptureContext(
            projectRoot: root,
            sessionID: "session:duplicate",
            agentName: "codex"
        )
        let firstSource = try ArtifactTestSupport.write(
            "first",
            named: "outside/first.md",
            under: root
        )
        let first = try await repository.importFile(
            sourceURL: firstSource,
            context: context,
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let originalSession = try sessionRoot(for: first, projectRoot: root)
        try copySession(
            originalSession,
            to: root.appendingPathComponent(".cmux/backup/session-copy")
        )
        let secondSource = try ArtifactTestSupport.write(
            "second",
            named: "outside/second.md",
            under: root
        )

        await #expect(throws: ArtifactStoreError.corruptProvenance(
            root.appendingPathComponent(".cmux").path
        )) {
            _ = try await repository.importFile(
                sourceURL: secondSource,
                context: context,
                provenance: .manual,
                configuration: .defaultValue,
                capturedAt: Date(timeIntervalSince1970: 2)
            )
        }
    }

    @Test("Capture rejects duplicate workspace identity markers")
    func captureRejectsDuplicateWorkspaceMarkers() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        let context = ArtifactCaptureContext(
            projectRoot: root,
            workspaceID: "workspace:duplicate",
            agentName: "codex"
        )
        let firstSource = try ArtifactTestSupport.write(
            "first",
            named: "outside/workspace-first.md",
            under: root
        )
        let first = try await repository.importFile(
            sourceURL: firstSource,
            context: context,
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let originalSession = try sessionRoot(for: first, projectRoot: root)
        try copySession(
            originalSession,
            to: root.appendingPathComponent(".cmux/backup/workspace-copy")
        )
        let secondSource = try ArtifactTestSupport.write(
            "second",
            named: "outside/workspace-second.md",
            under: root
        )

        await #expect(throws: ArtifactStoreError.corruptProvenance(
            root.appendingPathComponent(".cmux").path
        )) {
            _ = try await repository.importFile(
                sourceURL: secondSource,
                context: context,
                provenance: .manual,
                configuration: .defaultValue,
                capturedAt: Date(timeIntervalSince1970: 2)
            )
        }
    }

    @Test("Workspace-only capture does not reuse an agent-session directory")
    func workspaceOnlyCaptureStaysSeparateFromAgentSession() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        let agentSource = try ArtifactTestSupport.write(
            "agent",
            named: "outside/agent.md",
            under: root
        )
        let agent = try await repository.importFile(
            sourceURL: agentSource,
            context: ArtifactCaptureContext(
                projectRoot: root,
                workspaceID: "workspace:shared",
                sessionID: "session:agent",
                agentName: "codex"
            ),
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let manualSource = try ArtifactTestSupport.write(
            "manual",
            named: "outside/manual.md",
            under: root
        )

        let manual = try await repository.importFile(
            sourceURL: manualSource,
            context: ArtifactCaptureContext(
                projectRoot: root,
                workspaceID: "workspace:shared"
            ),
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 2)
        )

        #expect(
            try sessionRoot(for: agent, projectRoot: root)
                != sessionRoot(for: manual, projectRoot: root)
        )
    }

    private func sessionRoot(
        for outcome: ArtifactImportOutcome,
        projectRoot: URL
    ) throws -> URL {
        let relativePath = try #require(outcome.record?.relativePath)
        return projectRoot.appendingPathComponent(".cmux/\(relativePath)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func copySession(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
