import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("cmux Notes repository")
struct CmuxNoteRepositoryTests {
    @Test("Notes write, append, read, list, search, and delete through one live store")
    func noteLifecycle() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        let context = ArtifactCaptureContext(
            projectRoot: root,
            workspaceID: "workspace:notes",
            sessionID: "session:notes",
            agentName: "codex"
        )

        let written = try await repository.writeNote(
            name: "plans/launch",
            text: "first needle",
            mode: .replace,
            context: context
        )
        #expect(written.relativePath.hasSuffix("/notes/plans/launch.md"))
        #expect(written.reference == ".cmux/\(written.relativePath)")

        _ = try await repository.writeNote(
            name: "launch",
            text: "\nsecond line",
            mode: .append,
            context: context
        )
        #expect(try await repository.readNote(projectRoot: root, name: "launch")
            == "first needle\nsecond line")
        #expect(try await repository.listNotes(projectRoot: root).map(\.relativePath)
            == [written.relativePath])
        let results = try await repository.searchNotes(projectRoot: root, query: "needle")
        #expect(results.first?.note.relativePath == written.relativePath)
        #expect(results.first?.matchedContent == true)

        try await repository.deleteNote(projectRoot: root, name: written.reference)
        await #expect(throws: CmuxNoteStoreError.noteNotFound("launch")) {
            _ = try await repository.readNote(projectRoot: root, name: "launch")
        }
    }

    @Test("Moved notes and session folders remain discoverable without an index")
    func resolvesMovedNotesAndReusesMovedSession() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        let context = ArtifactCaptureContext(
            projectRoot: root,
            sessionID: "session:move",
            agentName: "codex"
        )
        let first = try await repository.writeNote(
            name: "plan",
            text: "movable",
            mode: .replace,
            context: context
        )
        let originalSession = URL(fileURLWithPath: first.absolutePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let movedSession = root.appendingPathComponent(".cmux/organized/research-session")
        try FileManager.default.createDirectory(
            at: movedSession.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: originalSession, to: movedSession)
        let movedNote = movedSession.appendingPathComponent("notes/archive/final.md")
        try FileManager.default.createDirectory(
            at: movedNote.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(
            at: movedSession.appendingPathComponent("notes/plan.md"),
            to: movedNote
        )

        #expect(try await repository.readNote(projectRoot: root, name: "final") == "movable")
        let second = try await repository.writeNote(
            name: "next",
            text: "same session",
            mode: .replace,
            context: context
        )
        #expect(second.relativePath == "organized/research-session/notes/next.md")
    }

    @Test("Bare writes stay isolated to the current agent session")
    func isolatesWritesBySession() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        let firstContext = ArtifactCaptureContext(
            projectRoot: root,
            sessionID: "session:first",
            agentName: "codex"
        )
        let secondContext = ArtifactCaptureContext(
            projectRoot: root,
            sessionID: "session:second",
            agentName: "codex"
        )
        let first = try await repository.writeNote(
            name: "plan",
            text: "first",
            mode: .replace,
            context: firstContext
        )

        let second = try await repository.writeNote(
            name: "plan",
            text: "second",
            mode: .replace,
            context: secondContext
        )
        _ = try await repository.writeNote(
            name: first.reference,
            text: "explicit update",
            mode: .replace,
            context: secondContext
        )

        let firstSessionRoot = first.relativePath.split(separator: "/").first
        let secondSessionRoot = second.relativePath.split(separator: "/").first
        #expect(first.relativePath.hasSuffix("/notes/plan.md"))
        #expect(second.relativePath.hasSuffix("/notes/plan.md"))
        #expect(firstSessionRoot != secondSessionRoot)
        #expect(try String(contentsOfFile: first.absolutePath, encoding: .utf8) == "explicit update")
        #expect(try String(contentsOfFile: second.absolutePath, encoding: .utf8) == "second")
    }

    @Test("Note mutations require exact names instead of fuzzy matches")
    func mutationsDoNotFuzzyMatch() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let repository = LocalArtifactRepository()
        let context = ArtifactCaptureContext(
            projectRoot: root,
            sessionID: "session:exact",
            agentName: "codex"
        )
        let plan = try await repository.writeNote(
            name: "plan",
            text: "original plan",
            mode: .replace,
            context: context
        )

        let shortName = try await repository.writeNote(
            name: "p",
            text: "short note",
            mode: .replace,
            context: context
        )

        #expect(plan.relativePath != shortName.relativePath)
        #expect(try await repository.readNote(projectRoot: root, name: "plan") == "original plan")
        #expect(try await repository.readNote(projectRoot: root, name: "p") == "short note")
        await #expect(throws: CmuxNoteStoreError.noteNotFound("pla")) {
            try await repository.deleteNote(projectRoot: root, name: "pla")
        }
        #expect(try await repository.listNotes(projectRoot: root).count == 2)
    }

    @Test("Notes reject traversal and never follow symlinked note files")
    func rejectsUnsafePaths() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let outside = try ArtifactTestSupport.write(
            "outside",
            named: "outside.md",
            under: root
        )
        let notes = root.appendingPathComponent(".cmux/session/notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: notes.appendingPathComponent("linked.md"),
            withDestinationURL: outside
        )
        let repository = LocalArtifactRepository()

        await #expect(throws: CmuxNoteStoreError.invalidName("../escape")) {
            _ = try await repository.writeNote(
                name: "../escape",
                text: "unsafe",
                mode: .replace,
                context: ArtifactCaptureContext(projectRoot: root)
            )
        }
        await #expect(throws: CmuxNoteStoreError.noteNotFound("linked")) {
            _ = try await repository.readNote(projectRoot: root, name: "linked")
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
    }

    @Test("Non-UTF-8 Markdown is not silently decoded as a Note")
    func rejectsInvalidUTF8() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let note = root.appendingPathComponent(".cmux/session/notes/binary.md")
        try FileManager.default.createDirectory(
            at: note.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF, 0xFE]).write(to: note)

        await #expect(throws: CmuxNoteStoreError.invalidUTF8("session/notes/binary.md")) {
            _ = try await LocalArtifactRepository().readNote(projectRoot: root, name: "binary")
        }
    }
}
