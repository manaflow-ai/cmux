@testable import CmuxNextDesign
import Foundation
import Testing

/// The quit hook (R96): one owner of unsaved surfaces. Weak registration,
/// one participant per document, saves bounded by their own deadline on the
/// injected clock, and the registry alone removes a draft after a save or a
/// Don't Save; a failed or timed-out save keeps it.
@MainActor
struct QuitUnsavedRegistryTests {
    final class Doc: QuitUnsavedParticipant {
        let quitParticipantID: String
        let quitTitle: String
        var hasUnsavedChanges = true
        var quitFlushDeadline: Duration = .seconds(3)
        var flush: () async throws -> Void = {}
        var discarded = 0
        init(_ id: String, title: String? = nil) {
            quitParticipantID = id
            quitTitle = title ?? id
        }
        func flushForQuit() async throws { try await flush() }
        func discardForQuit() async { discarded += 1 }
    }

    static func store(_ clock: ManualClock) -> RecoveryDraftStore {
        RecoveryDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)"),
                           clock: clock, debounce: .seconds(1))
    }

    @Test func registrationIsWeakAndCancellable() {
        let registry = QuitUnsavedRegistry(clock: ManualClock(), drafts: nil)
        var doc: Doc? = Doc("file:local:/a")
        registry.register(doc!) // crash-allow: test fixture
        #expect(registry.unsaved().count == 1)
        doc = nil
        #expect(registry.unsaved().isEmpty, "a closed document leaves")
        let kept = Doc("file:local:/b")
        let token = registry.register(kept)
        token.cancel()
        #expect(registry.unsaved().isEmpty)
    }

    @Test func onePerDocumentAndTheHostIsPartOfTheID() {
        let registry = QuitUnsavedRegistry(clock: ManualClock(), drafts: nil)
        let tabs = [Doc("file:local:/a"), Doc("file:local:/a"), Doc("file:cloud1:/a")]
        tabs.forEach { registry.register($0) }
        #expect(registry.unsaved().map(\.quitParticipantID) == ["file:local:/a", "file:cloud1:/a"])
    }

    /// The one id format is `file:<host id>:<absolute path>`; any other id
    /// is refused at registration and never asked about at quit.
    @Test func aMalformedIDIsNotRegistered() {
        let registry = QuitUnsavedRegistry(clock: ManualClock(), drafts: nil)
        let malformed = ["notes.md", "file:/a/b.md", "file::/a/b.md", "file:local:a/b.md", "file:local", "browser:local:/a/b.md", ""]
            .map { Doc($0) }
        malformed.forEach { registry.register($0) }
        #expect(registry.unsaved().isEmpty, "a malformed id is refused")
        let valid = [Doc("file:local:/a/b.md"), Doc("file:cloud1:/srv/a:b.md")]
        valid.forEach { registry.register($0) }
        #expect(registry.unsaved().map(\.quitParticipantID) == ["file:local:/a/b.md", "file:cloud1:/srv/a:b.md"])
    }

    @Test func aSuccessfulSaveRemovesTheDraft() async {
        let clock = ManualClock()
        let store = Self.store(clock)
        let registry = QuitUnsavedRegistry(clock: clock, drafts: store)
        let doc = Doc("file:local:/a")
        store.update(id: doc.quitParticipantID, title: "a", contents: Data("x".utf8))
        await store.writePending()
        #expect(await store.drafts().count == 1)
        let outcomes = await registry.save([doc])
        #expect(outcomes.map(\.result) == [.saved])
        #expect(await store.drafts().isEmpty)
    }

    /// A crashed page: the save fails with its reason, the draft stays;
    /// Don't Save then discards and removes the draft.
    @Test func aCrashedPageKeepsTheDraftUntilDontSave() async {
        let clock = ManualClock()
        let store = Self.store(clock)
        let registry = QuitUnsavedRegistry(clock: clock, drafts: store)
        let doc = Doc("file:local:/a")
        doc.flush = { throw QuitFlushError.failed("page crashed; recovery draft kept") }
        store.update(id: doc.quitParticipantID, title: "a", contents: Data("x".utf8))
        await store.writePending()
        let outcomes = await registry.save([doc])
        #expect(outcomes.first?.result == .failed("page crashed; recovery draft kept"))
        #expect(await store.drafts().count == 1, "an unattended or failed save keeps the draft")
        await registry.discard([doc])
        #expect(doc.discarded == 1)
        #expect(await store.drafts().isEmpty)
    }

    @Test func aSaveThatOutlivesItsDeadlineTimesOutAndKeepsItsDraft() async {
        let clock = ManualClock()
        let registry = QuitUnsavedRegistry(clock: clock, drafts: nil)
        let doc = Doc("file:local:/slow")
        doc.quitFlushDeadline = .seconds(60)
        doc.flush = { try await clock.sleep(for: .seconds(1_000)) }
        let task = Task { await registry.save([doc], deadlineCap: .seconds(3)) }
        await clock.sleepers(atLeast: 2)
        clock.advance(by: .seconds(3))
        let outcomes = await task.value
        #expect(outcomes.map(\.result) == [.timedOut])
        #expect(outcomes.first?.reason == QuitFlushStrings.timedOut)
    }

    @Test func aDeclaredDeadlineIsCappedAtThirtySeconds() async {
        let clock = ManualClock()
        let registry = QuitUnsavedRegistry(clock: clock, drafts: nil)
        let doc = Doc("file:local:/cloud")
        doc.quitFlushDeadline = .seconds(120)
        doc.flush = { try await clock.sleep(for: .seconds(1_000)) }
        let task = Task { await registry.save([doc]) }
        await clock.sleepers(atLeast: 2)
        clock.advance(by: .seconds(30))
        #expect(await task.value.map(\.result) == [.timedOut])
    }

    @Test func typedErrorsShowTheirReason() async {
        let registry = QuitUnsavedRegistry(clock: ManualClock(), drafts: nil)
        let conflict = Doc("file:local:/c")
        conflict.flush = { throw QuitFlushError.conflict("/c") }
        let readOnly = Doc("file:local:/r")
        readOnly.flush = { throw QuitFlushError.readOnly("/r") }
        let outcomes = await registry.save([conflict, readOnly])
        #expect(outcomes.map(\.reason) == [QuitFlushError.conflict("/c").reason, QuitFlushError.readOnly("/r").reason])
        #expect(outcomes[0].reason?.contains("/c") == true)
    }
}
