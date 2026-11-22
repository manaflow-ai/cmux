@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

/// The quit's unsaved step (R96 quit hook): Save (Return), Don't Save
/// (Command-D), Cancel (Escape); a failed save reopens the question with its
/// reason; a scripted quit refuses and names what did not save.
@MainActor
struct QuitUnsavedStepTests {
    final class Doc: QuitUnsavedParticipant {
        let quitParticipantID: String
        let quitTitle: String
        var hasUnsavedChanges = true
        var failures = 0
        var discarded = false
        init(_ id: String) {
            quitParticipantID = id
            quitTitle = id
        }
        func flushForQuit() async throws {
            if failures > 0 {
                failures -= 1
                throw QuitFlushError.failed("page crashed; recovery draft kept")
            }
            hasUnsavedChanges = false
        }
        func discardForQuit() async {
            discarded = true
            hasUnsavedChanges = false
        }
    }

    static func setup() -> (QuitUnsavedRegistry, CmuxDialogCenter) {
        (QuitUnsavedRegistry(clock: ContinuousClock(), drafts: nil), CmuxDialogCenter(host: CmuxDialogHeadlessHost()))
    }

    /// Presses `button` on the next dialog that shows (bounded wait).
    static func press(_ button: String, in center: CmuxDialogCenter, identifier: String = "cmux.dialog.quitUnsaved") async -> Bool {
        for _ in 0..<500 {
            if let record = center.records.first(where: { $0.spec.identifier == identifier }) {
                return center.press(record.id, button: button)
            }
            await Task.yield()
        }
        return false
    }

    @Test func theQuestionsKeys() {
        let spec = QuitUnsavedStep.spec([Doc("a")], failures: [:])
        #expect(spec.defaultButton?.id == QuitUnsavedStep.saveID)
        #expect(spec.cancelButton?.id == "cancel")
        #expect(spec.buttons.first { $0.key == "d" }?.id == QuitUnsavedStep.dontSaveID)
        #expect(spec.lines == ["a"])
    }

    @Test func saveThenQuit() async {
        let (registry, center) = Self.setup()
        let doc = Doc("file:local:/a")
        registry.register(doc)
        let task = Task { await QuitUnsavedStep.resolveInteractive(registry, scope: .app, center: center) }
        #expect(await Self.press(QuitUnsavedStep.saveID, in: center))
        #expect(await task.value)
        #expect(!doc.hasUnsavedChanges)
    }

    @Test func cancelStopsTheQuit() async {
        let (registry, center) = Self.setup()
        let doc = Doc("file:local:/a")  // the registry holds it weakly
        registry.register(doc)
        let task = Task { await QuitUnsavedStep.resolveInteractive(registry, scope: .app, center: center) }
        #expect(await Self.press("cancel", in: center))
        #expect(await task.value == false)
        #expect(doc.hasUnsavedChanges, "Cancel saves and discards nothing")
    }

    /// A crashed page: the question comes back with the reason; Don't Save
    /// then quits.
    @Test func aFailedSaveAsksAgainWithItsReason() async throws {
        let (registry, center) = Self.setup()
        let doc = Doc("file:local:/a")
        doc.failures = 1
        registry.register(doc)
        let task = Task { await QuitUnsavedStep.resolveInteractive(registry, scope: .app, center: center) }
        #expect(await Self.press(QuitUnsavedStep.saveID, in: center))
        var lines: [String] = []
        for _ in 0..<500 where lines.isEmpty {
            lines = center.records.first { $0.spec.identifier == "cmux.dialog.quitUnsaved" }?.spec.lines ?? []
            await Task.yield()
        }
        #expect(lines == [QuitStrings.unsavedFailed("file:local:/a", "page crashed; recovery draft kept")])
        #expect(await Self.press(QuitUnsavedStep.dontSaveID, in: center))
        #expect(await task.value)
        #expect(doc.discarded)
    }

    @Test func aScriptedQuitRefusesAndNamesWhatDidNotSave() {
        let outcomes = [QuitFlushOutcome(id: "1", title: "notes.md", result: .timedOut),
                        QuitFlushOutcome(id: "2", title: "todo.md", result: .saved)]
        let refusal = QuitUnsavedStep.refusal(outcomes)
        #expect(refusal == QuitStrings.unsavedRefused("notes.md"))
        #expect(refusal?.contains("Save or close them in the app") == true)
        #expect(QuitUnsavedStep.refusal([QuitFlushOutcome(id: "2", title: "todo.md", result: .saved)]) == nil)
    }
    // MARK: The update relaunch (SIDEBAR-FOOTER-MINIMAL)

    /// Runs `resolve` for `origin`; a question that shows is cancelled and
    /// returned, so a wrong dialog fails the test instead of hanging it.
    static func resolveShowingQuestion(_ origin: QuitOrigin, _ registry: QuitUnsavedRegistry,
                                       _ center: CmuxDialogCenter) async -> (result: Bool, question: CmuxDialogSpec?) {
        let task = Task { await QuitUnsavedStep.resolve(origin, registry: registry, scope: .app, center: center, writeDrafts: {}) }
        for _ in 0..<500 {
            if let record = center.records.first(where: { $0.spec.identifier == "cmux.dialog.quitUnsaved" }) {
                let spec = record.spec
                _ = center.press(record.id, button: "cancel")
                return (await task.value, spec)
            }
            await Task.yield()
        }
        return (await task.value, nil)
    }

    /// The update relaunch quits as explicit keep sessions. With no document
    /// open, or only documents without edits, no question shows and the quit
    /// goes on: the pill's one click never meets a dialog.
    @Test func theUpdateRelaunchAsksNothingWithoutUnsavedEdits() async {
        let (registry, center) = Self.setup()
        #expect(await Self.resolveShowingQuestion(.explicit(.keep), registry, center) == (true, nil))
        let clean = Doc("file:local:/clean.md")
        clean.hasUnsavedChanges = false
        registry.register(clean)
        let (result, question) = await Self.resolveShowingQuestion(.explicit(.keep), registry, center)
        #expect(result)
        #expect(question == nil, "a document without edits never shows the unsaved question")
        #expect(center.records.isEmpty)
    }

    /// Data loss protection: real unsaved edits still ask before the update
    /// relaunch, naming only the edited document.
    @Test func theUpdateRelaunchStillAsksForRealUnsavedEdits() async {
        let (registry, center) = Self.setup()
        let clean = Doc("file:local:/clean.md")
        clean.hasUnsavedChanges = false
        let edited = Doc("file:local:/edited.md")
        registry.register(clean)
        registry.register(edited)
        let (result, question) = await Self.resolveShowingQuestion(.explicit(.keep), registry, center)
        #expect(question?.lines == ["file:local:/edited.md"])
        #expect(result == false, "Cancel on that question stops the relaunch")
        #expect(edited.hasUnsavedChanges)
    }

    /// The unattended origins never ask, even with edits.
    @Test func signalAndScriptedQuitsNeverAsk() async {
        for origin: QuitOrigin in [.signal, .powerOff, .scripted] {
            let (registry, center) = Self.setup()
            let edited = Doc("file:local:/edited.md")
            registry.register(edited)
            let (result, question) = await Self.resolveShowingQuestion(origin, registry, center)
            #expect(result && question == nil)
            #expect(!edited.hasUnsavedChanges, "saved unattended")
        }
    }
}
