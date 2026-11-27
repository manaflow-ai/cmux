#if os(iOS)
import CmuxMobileArtifacts
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-21: the link lagged "and my drafted message on ios in the f***ing round composer got
/// lost". A reconnect replaces the terminal's model (the placeholder or the dropped session gives
/// way to a new one): the draft, and a send the Mac never got, come along.
@MainActor
@Suite struct ComposerDraftCarryTests {
    @MainActor
    final class StubSession: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {}
        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    func model() -> TerminalModel {
        TerminalModel(session: StubSession(), artifactSource: MockArtifactSource(), title: "zsh")
    }

    @Test func adoptingAttachmentsStartsUploadsWithAnAlreadyBoundUploader() async throws {
        let before = model()
        let file = ComposerAttachment(kind: .file, name: "draft.txt", data: Data("draft".utf8))
        before.addAttachment(file)

        let after = model()
        after.ingest(.connection(.attached))
        let (uploads, continuation) = AsyncStream<String>.makeStream()
        defer { continuation.finish() }
        after.setUploader({ _, name in
            continuation.yield(name)
            return "/workspace/" + name
        }, directory: "/workspace")

        // The live host binds the uploader before copying a replaced model's draft.
        // No send or subsequent connection event should be needed to begin transfer.
        after.adoptComposer(from: before)
        let uploaded = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                for await name in uploads { return name }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        #expect(uploaded == "draft.txt")
        #expect(after.attachments.map(\.id) == [file.id])
    }

    @Test func aRebuiltTerminalKeepsTheDraft() {
        let before = model()
        before.ingest(.connection(.attached))
        before.composerText = "half a command"
        // The link drops; the reconnect builds a new model for the same tab.
        before.ingest(.connection(.reattaching(mac: "cosmic")))
        let after = model()
        after.adoptComposer(from: before)
        #expect(after.composerText == "half a command")
    }

    @Test func aSendHeldForAnUnreachableMacComesBackWhenItsSessionIsReplaced() {
        let before = model()
        before.ingest(.connection(.reattaching(mac: "cosmic")))
        before.composerText = "make test"
        before.send()
        #expect(before.composerText.isEmpty)
        // Not acked yet: it is still the draft to keep.
        #expect(before.draftToKeep == "make test")
        let after = model()
        after.adoptComposer(from: before)
        #expect(after.composerText == "make test", "the old session stops with its hold: never silently lost")
        #expect(after.composerNotice == TerminalConnectionState.inputNotSentNotice)
    }

    @Test func theDraftIsWrittenAsItChangesAndGoesOnceSent() {
        let model = model()
        var kept: [String] = []
        model.onDraftChange = { [weak model] in kept.append(model?.draftToKeep ?? "?") }
        model.ingest(.connection(.attached))
        model.composerText = "ls"
        model.send()
        #expect(kept == ["ls", ""])
        // A cold start restores it, never over what is typed.
        model.restoreDraft("from disk")
        #expect(model.composerText == "from disk")
        model.restoreDraft("older")
        #expect(model.composerText == "from disk")
    }

    @Test func aHeldSendStaysTheDraftUntilTheTerminalIsBack() {
        let model = model()
        var kept: [String] = []
        model.onDraftChange = { [weak model] in kept.append(model?.draftToKeep ?? "?") }
        model.ingest(.connection(.reattaching(mac: "cosmic")))
        model.composerText = "deploy"
        model.send()
        #expect(model.draftToKeep == "deploy")
        // Attached again: the session's hold went out, so the draft goes.
        model.ingest(.connection(.attached))
        #expect(model.draftToKeep.isEmpty)
        #expect(kept.last == "")
    }
}
#endif
