@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The file pages' side of the R96 quit hook: one participant per document ("file:local:<path>"),
/// dirty from the first edit the page reports, a recovery draft on every edit (removed after a
/// normal save, an edit undone back to the file, or a close without saving), and a quit flush that
/// asks the pages first and otherwise writes the last reported text on its base hash.
@MainActor
@Suite(.serialized)
struct FileQuitDocumentTests {
    static func store(maxDraftBytes: Int = RecoveryDraftStore.defaultMaxDraftBytes) throws -> (RecoveryDraftStore, ManualClock) {
        let clock = ManualClock()
        let directory = try FileDocumentTests.folder().appending(path: "recovery", directoryHint: .isDirectory)
        return (RecoveryDraftStore(directory: directory, clock: clock, debounce: .seconds(1), maxDraftBytes: maxDraftBytes), clock)
    }

    static func file(_ text: String = "v1\n") throws -> URL {
        let folder = try FileDocumentTests.folder()
        let project = folder.appending(path: "api", directoryHint: .isDirectory)
        try FileDocumentTests.makeDirectory(project)
        let url = project.appending(path: "notes.md")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func theFirstEditMakesTheDocumentUnsavedAndWritesItsDraft() async throws {
        let (drafts, clock) = try Self.store()
        let url = try Self.file()
        let document = FileQuitDocument(url: url, drafts: drafts, writable: { true })
        #expect(document.quitParticipantID == "file:local:" + url.path)
        #expect(document.quitTitle == "notes.md (api)")
        #expect(!document.hasUnsavedChanges)
        #expect(document.edited(text: "v2\n", baseHash: FileDocument.hash(Data("v1\n".utf8))) == .kept)
        #expect(document.hasUnsavedChanges)
        _ = clock
        await drafts.writePending()
        let draft = try #require(await drafts.drafts().first)
        #expect(draft.id == document.quitParticipantID && draft.contents == Data("v2\n".utf8) && draft.filePath == url.path)
    }

    @Test func anEditUndoneBackToTheFileOrASaveIsCleanAndRemovesTheDraft() async throws {
        let (drafts, _) = try Self.store()
        let url = try Self.file()
        let base = FileDocument.hash(Data("v1\n".utf8))
        let document = FileQuitDocument(url: url, drafts: drafts, writable: { true })
        document.edited(text: "v2\n", baseHash: base)
        await drafts.writePending()
        document.edited(text: "v1\n", baseHash: base)
        #expect(!document.hasUnsavedChanges)
        await document.settled()
        #expect(await drafts.drafts().isEmpty)
        document.edited(text: "v3\n", baseHash: base)
        await drafts.writePending()
        document.saved(hash: FileDocument.hash(Data("v3\n".utf8)))
        #expect(!document.hasUnsavedChanges)
        await document.settled()
        #expect(await drafts.drafts().isEmpty)
    }

    @Test func aDraftOverTheLimitIsNotKept() throws {
        let (drafts, _) = try Self.store(maxDraftBytes: 4)
        let document = FileQuitDocument(url: try Self.file(), drafts: drafts, writable: { true })
        #expect(document.edited(text: "much longer than four bytes", baseHash: nil) == .tooLarge)
        #expect(document.hasUnsavedChanges)
    }

    /// The quit flush asks every page first; a page that saved leaves nothing to write.
    @Test func aQuitFlushAsksThePagesFirst() async throws {
        let (drafts, _) = try Self.store()
        let url = try Self.file()
        let document = FileQuitDocument(url: url, drafts: drafts, writable: { true })
        document.edited(text: "v2\n", baseHash: FileDocument.hash(Data("v1\n".utf8)))
        var asked = 0
        let stop = document.addFlusher {
            asked += 1
            document.saved(hash: FileDocument.hash(Data("v2\n".utf8)))
            return false
        }
        try await document.flushForQuit()
        #expect(asked == 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == "v1\n", "the page saved; the host wrote nothing")
        stop()
    }

    /// No page answers (or one is still dirty): the host writes the last reported text on its base.
    @Test func aQuitFlushWritesTheLastReportedTextOrSaysWhyItCannot() async throws {
        let (drafts, _) = try Self.store()
        let url = try Self.file()
        let base = FileDocument.hash(Data("v1\n".utf8))
        let document = FileQuitDocument(url: url, drafts: drafts, writable: { true })
        document.edited(text: "v2\n", baseHash: base)
        try await document.flushForQuit()
        #expect(try String(contentsOf: url, encoding: .utf8) == "v2\n")
        #expect(!document.hasUnsavedChanges)

        let conflicted = FileQuitDocument(url: url, drafts: drafts, writable: { true })
        conflicted.edited(text: "mine\n", baseHash: base)
        await #expect(throws: QuitFlushError.conflict("notes.md")) { try await conflicted.flushForQuit() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "v2\n")

        let locked = FileQuitDocument(url: url, drafts: drafts, writable: { false })
        locked.edited(text: "mine\n", baseHash: FileDocument.hash(Data("v2\n".utf8)))
        await #expect(throws: QuitFlushError.readOnly("notes.md")) { try await locked.flushForQuit() }
    }

    /// A page that reported text and then crashed answers no flush (its call fails, so it counts
    /// as still dirty): the host writes the reported text only while the disk still matches the
    /// base hash that text was edited from.
    @Test func aCrashedPagesLastTextIsWrittenOnlyOnItsBase() async throws {
        let (drafts, _) = try Self.store()
        let url = try Self.file()
        let base = FileDocument.hash(Data("v1\n".utf8))
        let document = FileQuitDocument(url: url, drafts: drafts, writable: { true })
        document.edited(text: "reported\n", baseHash: base)
        let stop = document.addFlusher { true }
        try await document.flushForQuit()
        #expect(try String(contentsOf: url, encoding: .utf8) == "reported\n")
        stop()

        let changed = FileQuitDocument(url: url, drafts: drafts, writable: { true })
        changed.edited(text: "mine\n", baseHash: FileDocument.hash(Data("reported\n".utf8)))
        let stopChanged = changed.addFlusher { true }
        try Data("changed on disk\n".utf8).write(to: url)
        await #expect(throws: QuitFlushError.conflict("notes.md")) { try await changed.flushForQuit() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "changed on disk\n")
        #expect(changed.hasUnsavedChanges)
        stopChanged()
    }

    /// A crashed page's flush call never returns: each page gets the flush timeout (on the
    /// injected clock), then the host writes the reported text on its base hash.
    @Test func aPageThatNeverAnswersTheFlushStillLetsTheHostWrite() async throws {
        let (drafts, _) = try Self.store()
        let url = try Self.file()
        let clock = ManualClock()
        let document = FileQuitDocument(url: url, drafts: drafts, writable: { true }, clock: clock)
        document.edited(text: "reported\n", baseHash: FileDocument.hash(Data("v1\n".utf8)))
        let stop = document.addFlusher {
            // A page that never answers: this waits until the test ends.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return true
        }
        let quit = Task { try await document.flushForQuit() }
        await clock.sleepers(atLeast: 1)
        clock.advance(by: FileQuitDocument.pageFlushTimeout)
        try await quit.value
        #expect(try String(contentsOf: url, encoding: .utf8) == "reported\n")
        stop()
    }

    /// Two tabs on one file whose pages both never answer (both crashed): the pages are asked
    /// together within one page timeout, so the host's write still lands inside the registry's own
    /// 3 s deadline (QuitUnsavedRegistry races each flush against a DemandTimer).
    @Test func twoDeadPagesStillSaveInsideTheRegistrysDeadline() async throws {
        let (drafts, _) = try Self.store()
        let url = try Self.file()
        let clock = ManualClock()
        let registry = QuitUnsavedRegistry(clock: clock, drafts: drafts)
        let document = FileQuitDocument(url: url, drafts: drafts, writable: { true }, clock: clock)
        let registration = registry.register(document)
        document.edited(text: "reported\n", baseHash: FileDocument.hash(Data("v1\n".utf8)))
        let never: () async -> Bool = {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return true
        }
        let stops = [document.addFlusher(never), document.addFlusher(never)]
        let quit = Task { await registry.save(registry.unsaved(), deadlineCap: .seconds(3)) }
        // The registry's deadline and the one wait for both pages are asleep on the clock.
        await clock.sleepers(atLeast: 2)
        clock.advance(by: FileQuitDocument.pageFlushTimeout)
        let outcomes = await quit.value
        #expect(outcomes.map(\.result) == [.saved])
        #expect(try String(contentsOf: url, encoding: .utf8) == "reported\n")
        stops.forEach { $0() }
        registration.cancel()
    }

    /// When the registry's deadline does pass (a page wait longer than it) and the person then
    /// chooses Don't Save, the late flush never writes: a timeout does not cancel the participant's
    /// task, so the participant itself must stop.
    @Test func afterTheRegistryTimesOutAndDontSaveNothingIsWritten() async throws {
        let (drafts, _) = try Self.store()
        let url = try Self.file()
        let clock = ManualClock()
        let registry = QuitUnsavedRegistry(clock: clock, drafts: drafts)
        let document = FileQuitDocument(url: url, drafts: drafts, writable: { true }, clock: clock, pageFlushTimeout: .seconds(10))
        let registration = registry.register(document)
        document.edited(text: "reported\n", baseHash: FileDocument.hash(Data("v1\n".utf8)))
        let stop = document.addFlusher {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return true
        }
        let participants = registry.unsaved()
        let quit = Task { await registry.save(participants, deadlineCap: .seconds(3)) }
        await clock.sleepers(atLeast: 2)
        clock.advance(by: .seconds(3))
        #expect(await quit.value.map(\.result) == [.timedOut])
        await registry.discard(participants)
        clock.advance(by: .seconds(10))
        await document.settled()
        #expect(try String(contentsOf: url, encoding: .utf8) == "v1\n", "Don't Save: the late flush writes nothing")
        stop()
        registration.cancel()
    }

    /// Don't Save: a flush after it asks no page and writes nothing.
    @Test func noHostWriteHappensAfterDontSave() async throws {
        let (drafts, _) = try Self.store()
        let url = try Self.file()
        let document = FileQuitDocument(url: url, drafts: drafts, writable: { true })
        document.edited(text: "v2\n", baseHash: FileDocument.hash(Data("v1\n".utf8)))
        var asked = 0
        let stop = document.addFlusher { asked += 1; return true }
        await document.discardForQuit()
        try await document.flushForQuit()
        #expect(asked == 0, "a discarded document asks no page to save")
        #expect(try String(contentsOf: url, encoding: .utf8) == "v1\n")
        stop()
    }

    @Test func discardAndACloseWithoutSavingDropTheUnsavedState() async throws {
        let (drafts, _) = try Self.store()
        let document = FileQuitDocument(url: try Self.file(), drafts: drafts, writable: { true })
        document.edited(text: "v2\n", baseHash: nil)
        await document.discardForQuit()
        #expect(!document.hasUnsavedChanges)
        document.edited(text: "v3\n", baseHash: nil)
        await drafts.writePending()
        document.closedWithoutSaving()
        await document.settled()
        #expect(!document.hasUnsavedChanges)
        #expect(await drafts.drafts().isEmpty)
    }

    /// The pages report edits through `cmux.<page>.edited`; two tabs on one file are one document
    /// in the quit registry.
    @Test func twoTabsOnOneFileAreOneParticipant() async throws {
        let (drafts, _) = try Self.store()
        let registry = QuitUnsavedRegistry(clock: ManualClock(), drafts: drafts)
        let documents = FileQuitDocuments(drafts: drafts, registry: registry)
        let url = try Self.file()
        let first = try #require(documents.document(for: url, holder: "cmux.markdown:a", writable: { true }))
        let second = try #require(documents.document(for: url, holder: "cmux.editor:b", writable: { true }))
        #expect(first === second)
        first.edited(text: "v2\n", baseHash: nil)
        #expect(registry.unsaved().map(\.quitParticipantID) == ["file:local:" + url.path])
        // Closing one of the two tabs keeps the other's edits; the last close drops them.
        documents.release(url, holder: "cmux.markdown:a")
        #expect(registry.unsaved().count == 1)
        documents.release(url, holder: "cmux.editor:b")
        #expect(registry.unsaved().isEmpty)
        let (provider, host, folder, _) = try FilePageProviderTests.world(.editor, file: "main.swift", text: "let x = 1\n")
        let reply = try await FilePageProviderTests.call(provider, "cmux.editor.edited",
                                                         ["path": .string(folder.appending(path: "main.swift").path), "text": "let x = 2\n",
                                                          "baseHash": .string(FileDocument.hash(Data("let x = 1\n".utf8)))])
        #expect(reply["recovery"]?.stringValue == "kept")
        #expect(host.edits.map(\.text) == ["let x = 2\n"])
    }

    // MARK: R96 v2

    /// The id is `QuitParticipantID.file(path:)` (host "local"). A malformed id is refused by the
    /// registry (an inactive registration): no document, no draft, and the page hears `invalidID`,
    /// not the too-large toast.
    @Test func aMalformedIDIsRefusedAndReportedAsInvalid() async throws {
        let (drafts, _) = try Self.store()
        let registry = QuitUnsavedRegistry(clock: ManualClock(), drafts: drafts)
        let url = try Self.file()
        #expect(FileQuitDocument(url: url, drafts: drafts, writable: { true }).quitParticipantID
            == QuitParticipantID.file(path: url.path))
        let refused = FileQuitDocuments(drafts: drafts, registry: registry, participantID: { _ in "notes.md" })
        #expect(refused.document(for: url, holder: "cmux.editor:a", writable: { true }) == nil)
        #expect(registry.unsaved().isEmpty)
        let bad = FileQuitDocument(url: url, id: "notes.md", drafts: drafts, writable: { true })
        #expect(bad.edited(text: "v2\n", baseHash: nil) == .invalidID)
        await drafts.writePending()
        #expect(await drafts.drafts().isEmpty)

        let (provider, host, folder, _) = try FilePageProviderTests.world(.editor, file: "main.swift", text: "let x = 1\n")
        host.acceptance = .invalidID
        let reply = try await FilePageProviderTests.call(provider, "cmux.editor.edited",
                                                         ["path": .string(folder.appending(path: "main.swift").path), "text": "let x = 2\n"])
        #expect(reply["recovery"]?.stringValue == "invalidID")
    }

    /// The draft carries the hash its edits were based on, not the file at the delayed write.
    @Test func aDraftCarriesTheBaseHash() async throws {
        let (drafts, _) = try Self.store()
        let url = try Self.file()
        let base = FileDocument.hash(Data("v1\n".utf8))
        let document = FileQuitDocument(url: url, drafts: drafts, writable: { true })
        document.edited(text: "v2\n", baseHash: base)
        await drafts.writePending()
        let draft = try #require(await drafts.drafts().first)
        #expect(draft.base?.contentHash == base)
        #expect(!(await drafts.fileChangedSince(draft)))
    }

    /// A change made on disk during the draft's debounce is a conflict at restore: the base is the
    /// edit's, so the delayed write cannot hide the change.
    @Test func anOutsideChangeDuringTheDebounceIsAConflictAtRestore() async throws {
        let (drafts, _) = try Self.store()
        let url = try Self.file()
        let document = FileQuitDocument(url: url, drafts: drafts, writable: { true })
        document.edited(text: "mine\n", baseHash: FileDocument.hash(Data("v1\n".utf8)))
        try Data("outside\n".utf8).write(to: url)
        await drafts.writePending()
        let draft = try #require(await drafts.drafts().first)
        #expect(await drafts.fileChangedSince(draft))
    }

    /// The restore handler gets no "changed on disk" flag: the page compares the file's hash with
    /// the draft's base itself. Changed: the draft opens as unsaved changes with a conflict notice.
    /// The file is never written on open.
    @Test func aRestoreAfterAnOutsideChangeShowsTheConflictAndNeverWrites() async throws {
        let (drafts, _) = try Self.store()
        let url = try Self.file()
        let document = FileQuitDocument(url: url, drafts: drafts, writable: { true })
        document.edited(text: "mine\n", baseHash: FileDocument.hash(Data("v1\n".utf8)))
        await drafts.writePending()
        let draft = try #require(await drafts.drafts().first)
        let same = try #require(await FilePageRecovery.restore(draft))
        #expect(same.url.path == url.path && same.text == "mine\n" && !same.conflict)

        try Data("outside\n".utf8).write(to: url)
        let changed = try #require(await FilePageRecovery.restore(draft))
        #expect(changed.conflict && changed.text == "mine\n")
        let (provider, _, folder, _) = try FilePageProviderTests.world(.editor, file: "main.swift", text: "let x = 1\n")
        provider.recoveredText = "let x = 9\n"
        _ = try await FilePageProviderTests.call(provider, "cmux.editor.config")
        #expect(try String(contentsOf: url, encoding: .utf8) == "outside\n")
        #expect(try String(contentsOf: folder.appending(path: "main.swift"), encoding: .utf8) == "let x = 1\n")
    }

    /// D11: a recovered markdown draft opens in the markdown page, the viewer of its file type,
    /// not in the code editor. The launch notice's Open runs the bound restore handler; the handler
    /// is read at once after binding, so no other suite's binding replaces it.
    @Test func aRecoveredMarkdownDraftOpensInTheMarkdownPage() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        let restore = try #require(RecoveryDraftStore.shared.restoreHandler)
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let window = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(window)
        await BrowserTabTests.settle { window.content?.panes.isEmpty == false }
        let pane = try #require(window.content?.panes.values.first)
        let url = try Self.file()
        restore(RecoveryDraft(id: QuitParticipantID.file(path: url.path), title: "notes.md", savedAt: Date(),
                              contents: Data("mine\n".utf8), filePath: url.path))
        // The restore reads the file off the main actor, so wait on the tab, bounded.
        for _ in 0..<400 where services.pages.tabIDs(in: pane.paneKey).isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let keys = services.pages.tabIDs(in: pane.paneKey)
        #expect(keys.compactMap(LocalPageTab.page(of:)) == [.markdown])
        let key = try #require(keys.first)
        #expect(services.viewers.markdownPages.file(key)?.path == url.resolvingSymlinksInPath().path)
        #expect(try String(contentsOf: url, encoding: .utf8) == "v1\n", "opening never writes the file")
    }

    /// D11: the markdown page takes a recovered draft as the editor page does, once, as an unsaved edit.
    @Test func theMarkdownPageTakesARecoveredDraftOnce() async throws {
        let (provider, _, folder, _) = try FilePageProviderTests.world(.markdown, text: "# Title\n")
        provider.recoveredText = "# Mine\n"
        let config = try await FilePageProviderTests.call(provider, "cmux.markdown.config")
        #expect(config["recoveredText"]?.stringValue == "# Mine\n")
        #expect(config["text"]?.stringValue == "# Title\n")
        #expect(try await FilePageProviderTests.call(provider, "cmux.markdown.config")["recoveredText"] == nil)
        #expect(try String(contentsOf: folder.appending(path: "README.md"), encoding: .utf8) == "# Title\n")
    }

    /// A recovered draft opens in the code editor page as an unsaved edit.
    @Test func aRecoveredDraftOpensAsAnUnsavedEdit() async throws {
        let (provider, _, _, _) = try FilePageProviderTests.world(.editor, file: "main.swift", text: "let x = 1\n")
        provider.recoveredText = "let x = 9\n"
        let config = try await FilePageProviderTests.call(provider, "cmux.editor.config")
        #expect(config["recoveredText"]?.stringValue == "let x = 9\n")
        #expect(config["text"]?.stringValue == "let x = 1\n")
        // The page takes it once.
        #expect(try await FilePageProviderTests.call(provider, "cmux.editor.config")["recoveredText"] == nil)
        #expect(FilePageRecovery.document(of: RecoveryDraft(id: QuitParticipantID.file(path: "/tmp/a.md"), title: "a.md", savedAt: Date(),
                                                            contents: Data(), filePath: "/tmp/a.md")) == URL(fileURLWithPath: "/tmp/a.md"))
        #expect(FilePageRecovery.document(of: RecoveryDraft(id: "file:cloud-1:/tmp/a.md", host: "cloud-1", title: "a.md",
                                                            savedAt: Date(), contents: Data(), filePath: "/tmp/a.md")) == nil)
    }
}
