import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import Foundation
import Testing

/// The recovered-draft toast shows once per draft, not at every launch (Leo 2026-10-30: "STOP
/// SHOWING FUCKING BULLSHIT ON LOAD"). Each launch is a fresh store over the same recovery
/// directory, as the app makes one at launch; the draft stays on disk and restorable throughout.
@MainActor @Suite(.serialized, .closesItsWindows) struct RecoveryNoticeOnceTests {
    /// Records the toast views (the center's overlay host, without an overlay).
    @MainActor private final class RecordingHost: CmuxToastHosting {
        func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, appearing: Bool, windowGone: @escaping () -> Void) {}
        func move(_ toast: CmuxToastView, to slot: Int) {}
        func hide(_ toast: CmuxToastView, animated: Bool) {}
    }

    private static let id = QuitParticipantID.file(path: "/tmp/recovery-notice-once/notes.md")

    private static func directory() -> URL {
        URL(fileURLWithPath: "/tmp/rno-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    private static func writeDraft(savedAt seconds: TimeInterval, text: String, in directory: URL) async {
        let draft = RecoveryDraft(id: id, title: "notes.md", savedAt: Date(timeIntervalSince1970: seconds),
                                  contents: Data(text.utf8))
        await RecoveryDraftFiles.write(draft, in: directory, maxTotalBytes: .max)
    }

    /// One launch: a new store over `directory` shows its notice in a new window; the toasts it showed.
    private static func launch(_ directory: URL) async -> [CmuxToast] {
        let store = RecoveryDraftStore(directory: directory)
        let toasts = CmuxToastCenter(host: RecordingHost())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        await RecoveryNotice.show(store: store, toasts: toasts, in: window)
        let shown = toasts.toasts(in: window)
        for toast in shown { _ = toasts.close(id: toast.id, in: window) }
        return shown
    }

    @Test func aDraftToastsOnTheFirstLaunchOnly() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await Self.writeDraft(savedAt: 1000, text: "first", in: directory)

        #expect(await Self.launch(directory).map(\.id) == ["recovery:\(Self.id)"], "the first launch toasts the draft")
        #expect(await Self.launch(directory).isEmpty, "the second launch with the same draft toasted it again")
        #expect(await Self.launch(directory).isEmpty, "the third launch with the same draft toasted it again")
        // The draft itself stays, still restorable through Open.
        #expect(await RecoveryDraftStore(directory: directory).drafts().map(\.id) == [Self.id])
    }

    @Test func aNewerDraftOfTheSameDocumentToastsAgain() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await Self.writeDraft(savedAt: 1000, text: "first", in: directory)
        #expect(await Self.launch(directory).count == 1)
        #expect(await Self.launch(directory).isEmpty)

        await Self.writeDraft(savedAt: 2000, text: "second", in: directory)
        #expect(await Self.launch(directory).map(\.id) == ["recovery:\(Self.id)"], "a newer draft for the same id did not toast")
        #expect(await Self.launch(directory).isEmpty, "the newer draft toasted again at the next launch")
    }

    /// A launch that read the drafts but showed no toast (a crash, a closed window) records
    /// nothing: the record is written only once the toast is up (Codex review of #28305).
    @Test func aDraftWhoseToastNeverShowedStillToasts() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await Self.writeDraft(savedAt: 1000, text: "first", in: directory)
        #expect(await RecoveryDraftStore(directory: directory).unannouncedDrafts().map(\.id) == [Self.id])
        #expect(await RecoveryDraftStore(directory: directory).unannouncedDrafts().map(\.id) == [Self.id])
        #expect(await Self.launch(directory).count == 1)
        #expect(await RecoveryDraftStore(directory: directory).unannouncedDrafts().isEmpty)
    }

    @Test func noDraftShowsNothing() async {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await Self.launch(directory).isEmpty)
    }

    /// Removing the draft (a save, Don't Save) also drops its record: nothing is left in the directory.
    @Test func removingTheDraftDropsItsRecord() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await Self.writeDraft(savedAt: 1000, text: "first", in: directory)
        #expect(await Self.launch(directory).count == 1)

        await RecoveryDraftStore(directory: directory).remove(id: Self.id)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left.isEmpty, "left after the draft was removed: \(left)")
        #expect(await Self.launch(directory).isEmpty)
    }
}
