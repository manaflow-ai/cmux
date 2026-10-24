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
        let first = AppServices(environment: AppEnvironment.current([:]))
        let second = AppServices(environment: AppEnvironment.current([:]))
        let participant = Unsaved(path: root.appendingPathComponent("notes.md").path)
        let registration = first.quit.unsaved.register(participant)
        defer { registration.cancel() }

        #expect(registration.isActive)
        #expect(first.quit.unsaved.unsaved().map(\.quitParticipantID) == [participant.quitParticipantID])
        #expect(second.quit.unsaved.unsaved().isEmpty)
    }
}
