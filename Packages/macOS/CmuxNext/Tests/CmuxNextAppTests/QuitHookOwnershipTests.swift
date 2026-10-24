import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

/// A temporary directory of its own for one test.
private func quitHookTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cn-quit-hook-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The R96 quit hook has no process-wide instance (architecture B3): each app's
/// composition root (`AppServices`) owns its recovery-draft store, its unsaved
/// registry and its file quit documents, and the quit, the file pages and the
/// update handoff read those. Two apps in one process never share a participant,
/// `FileQuitDocuments` writes drafts to the store it is given, and one file shown
/// by two tabs is one document that the quit asks once. Each test uses its own
/// `AppServices` or its own temporary directory, so the suite runs in parallel.
@MainActor @Suite struct QuitHookOwnershipTests {
    /// A document with unsaved edits.
    private final class Unsaved: QuitUnsavedParticipant {
        let quitParticipantID: String
        let quitTitle = "notes.md (tests)"
        var hasUnsavedChanges = true
        init(path: String) { quitParticipantID = QuitParticipantID.file(path: path) }
        func flushForQuit() async throws { hasUnsavedChanges = false }
        func discardForQuit() async { hasUnsavedChanges = false }
    }

    /// Two `AppServices` give two unsaved registries, two recovery-draft stores
    /// in the directories they are given, and two file document sets: a
    /// participant that joins one app's quit hook is not seen by the other, and
    /// a file page edit in one app writes its draft to that app's directory
    /// only. Before B3, `AppServices` had no such properties, so this test did
    /// not compile there; it guards ownership, and the static_shared ratchet
    /// guards against a new `.shared`.
    @Test func twoQuitCoordinatorsDoNotShareParticipants() async throws {
        _ = NSApplication.shared
        let root = try quitHookTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstDrafts = root.appendingPathComponent("first-recovery", isDirectory: true)
        let secondDrafts = root.appendingPathComponent("second-recovery", isDirectory: true)
        var firstEnvironment = AppEnvironment.current([:])
        firstEnvironment.recoveryDraftsDirectory = firstDrafts
        var secondEnvironment = AppEnvironment.current([:])
        secondEnvironment.recoveryDraftsDirectory = secondDrafts
        let first = AppServices(environment: firstEnvironment)
        let second = AppServices(environment: secondEnvironment)
        let participant = Unsaved(path: root.appendingPathComponent("notes.md").path)
        let registration = first.quit.unsaved.register(participant)
        defer { registration.cancel() }

        #expect(registration.isActive)
        #expect(first.quit.unsaved.unsaved().map(\.quitParticipantID) == [participant.quitParticipantID])
        #expect(second.quit.unsaved.unsaved().isEmpty)
        #expect(first.quit.unsaved === first.quitUnsaved)

        // A file page edit joins its own app's quit hook (the registry the quit reads) and writes
        // its draft to that app's directory only.
        let file = root.appendingPathComponent("other.md")
        try Data("old".utf8).write(to: file)
        let document = try #require(first.fileQuitDocuments.document(for: file, holder: "tab-1", writable: { true }))
        #expect(second.fileQuitDocuments.existing(file) == nil)
        #expect(document.edited(text: "new", baseHash: FileDocument.hash(Data("old".utf8))) == .kept)
        #expect(first.quit.unsaved.unsaved().map(\.quitParticipantID).contains(document.quitParticipantID))
        #expect(second.quit.unsaved.unsaved().isEmpty)
        await first.recoveryDrafts.writePending()
        await second.recoveryDrafts.writePending()

        #expect(await first.recoveryDrafts.drafts().map(\.id) == [document.quitParticipantID])
        #expect(await second.recoveryDrafts.drafts().isEmpty)
        let written = try FileManager.default.contentsOfDirectory(at: firstDrafts, includingPropertiesForKeys: nil)
        #expect(written.filter { $0.pathExtension == "draft" }.count == 1)
        first.fileQuitDocuments.release(file, holder: "tab-1")
        await document.settled()
    }

    /// Unit test of `FileQuitDocuments`: a file page edit's draft lands in the
    /// directory of the store it was given. It does not test the composition
    /// root's wiring of the store.
    @Test func fileQuitDocumentsWriteDraftsToTheirStoresDirectory() async throws {
        let root = try quitHookTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let draftsDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        let file = root.appendingPathComponent("notes.md")
        try Data("old".utf8).write(to: file)
        let drafts = RecoveryDraftStore(directory: draftsDirectory)
        let documents = FileQuitDocuments(drafts: drafts, registry: QuitUnsavedRegistry(drafts: drafts))

        let document = try #require(documents.document(for: file, holder: "tab-1", writable: { true }))
        #expect(document.edited(text: "new", baseHash: FileDocument.hash(Data("old".utf8))) == .kept)
        await drafts.writePending()

        let stored = await drafts.drafts()
        #expect(stored.map(\.id) == [document.quitParticipantID])
        #expect(stored.first.map { String(decoding: $0.contents, as: UTF8.self) } == "new")
        let written = try FileManager.default.contentsOfDirectory(at: draftsDirectory, includingPropertiesForKeys: nil)
        #expect(written.filter { $0.pathExtension == "draft" }.count == 1)
        documents.release(file, holder: "tab-1")
        await document.settled()
    }

    /// A markdown tab and an editor tab on one file are one document: the quit
    /// sees one participant and saves it once, each tab's page is asked once,
    /// the host writes the text the pages reported, and the one draft on disk goes.
    @Test func aFileDocumentRegisteredBeforeQuitIsAskedOnce() async throws {
        let root = try quitHookTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.md")
        try Data("old".utf8).write(to: file)
        let drafts = RecoveryDraftStore(directory: root.appendingPathComponent("recovery", isDirectory: true))
        let registry = QuitUnsavedRegistry(drafts: drafts)
        let documents = FileQuitDocuments(drafts: drafts, registry: registry)

        let markdown = try #require(documents.document(for: file, holder: "markdown-tab", writable: { true }))
        let editor = try #require(documents.document(for: file, holder: "editor-tab", writable: { true }))
        #expect(markdown === editor)
        #expect(markdown.edited(text: "new", baseHash: FileDocument.hash(Data("old".utf8))) == .kept)
        await drafts.writePending()
        #expect(await drafts.drafts().count == 1)
        // Each tab's page holds its own flusher, as in the app; neither page saves, so the host
        // writes the last reported text.
        var markdownAsks = 0
        var editorAsks = 0
        let removeMarkdownFlusher = markdown.addFlusher {
            markdownAsks += 1
            return true
        }
        let removeEditorFlusher = editor.addFlusher {
            editorAsks += 1
            return true
        }
        defer {
            removeMarkdownFlusher()
            removeEditorFlusher()
        }

        let unsaved = registry.unsaved()
        #expect(unsaved.count == 1)
        let outcomes = await registry.save(unsaved)

        // One outcome: the file is written once (a second write on the old base hash would conflict).
        #expect(outcomes.map(\.result) == [.saved])
        #expect(markdownAsks == 1)
        #expect(editorAsks == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
        #expect(registry.unsaved().isEmpty)
        #expect(await drafts.drafts().isEmpty)
    }
}
