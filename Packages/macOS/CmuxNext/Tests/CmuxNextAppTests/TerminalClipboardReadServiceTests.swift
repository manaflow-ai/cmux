@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import Testing

/// CLIPBOARD-READ-BROKER layer 4, the dialog path of
/// `TerminalClipboardReadService`: the broker's `ask` puts one cmux dialog
/// per read, headless here. Allow replies with the pasteboard text; Deny,
/// Escape and a dismissal refuse; a daemon cancel closes the dialog with no
/// reply. Return never grants.
@MainActor @Suite(.timeLimit(.minutes(1))) struct TerminalClipboardReadServiceTests {
    static let terminal = "term_0123456789abcdef0123456789abcdef"

    struct Reply: Equatable {
        var id: String
        var text: String?
    }

    /// A broker wired to the service's dialog `ask` on a headless center,
    /// with fake subscribe, reply and pasteboard.
    @MainActor final class Harness {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var replies: [Reply] = []
        private(set) var broker: TerminalClipboardBroker!

        init() {
            broker = TerminalClipboardBroker(host: ClipboardReadHost(kind: .local), environment: .init(
                setting: { .ask },
                pasteboardText: { _ in "copied text" },
                ask: TerminalClipboardReadService.dialogAsk(center: center) { _ in
                    .init(terminalTitle: "build", scope: .app)
                },
                subscribe: { _ in },
                reply: { [unowned self] id, text in replies.append(Reply(id: id, text: text)) }))
        }

        /// Connects, subscribes the terminal, and opens the dialog for read `id`.
        func ask(_ id: String) async throws -> Int {
            broker.setConnection(1)
            broker.setTerminals([TerminalClipboardReadServiceTests.terminal])
            await broker.subscribing?.value
            broker.handle(.terminalClipboardRead(TerminalClipboardRead(
                requestID: id, terminalID: TerminalClipboardReadServiceTests.terminal, location: .standard,
                host: ClipboardReadHost(kind: .local))))
            let record = try #require(center.records.first)
            #expect(center.records.count == 1)
            #expect(record.spec.identifier == ClipboardReadStrings.identifier)
            #expect(record.spec.lines == [ClipboardReadStrings.message(terminal: "build", host: ClipboardReadStrings.thisMac)])
            #expect(broker.openRequests == [id])
            return record.id
        }

        func settle() async {
            await broker.lastReply?.value
        }
    }

    @Test func allowRepliesWithThePasteboardText() async throws {
        let h = Harness()
        let id = try await h.ask("r1")
        #expect(h.center.press(id, button: ClipboardReadStrings.allowID))
        await h.settle()
        #expect(h.replies == [Reply(id: "r1", text: "copied text")])
        #expect(h.center.records.isEmpty && h.broker.openRequests.isEmpty)
    }

    @Test func denyRepliesNull() async throws {
        let h = Harness()
        let id = try await h.ask("r1")
        #expect(h.center.press(id, button: ClipboardReadStrings.denyID))
        await h.settle()
        #expect(h.replies == [Reply(id: "r1", text: nil)])
        #expect(h.center.records.isEmpty)
    }

    @Test func dismissingTheDialogRefuses() async throws {
        let h = Harness()
        let id = try await h.ask("r1")
        #expect(h.center.dismiss(id))
        await h.settle()
        #expect(h.replies == [Reply(id: "r1", text: nil)])
        #expect(h.broker.openRequests.isEmpty)
    }

    /// Return is not Allow: the question stays open. Escape refuses.
    @Test func returnDoesNothingAndEscapeRefuses() async throws {
        let h = Harness()
        let id = try await h.ask("r1")
        #expect(!h.center.key(.return, in: id))
        await h.settle()
        #expect(h.replies.isEmpty && h.center.records.count == 1)
        #expect(h.center.key(.escape, in: id))
        await h.settle()
        #expect(h.replies == [Reply(id: "r1", text: nil)])
        #expect(h.center.records.isEmpty)
    }

    @Test func aCancelClosesTheDialogWithNoReply() async throws {
        let h = Harness()
        _ = try await h.ask("r1")
        h.broker.handle(.terminalClipboardReadCancelled(requestID: "r1"))
        await h.settle()
        #expect(h.center.records.isEmpty, "the cancel closed the dialog")
        #expect(h.replies.isEmpty, "the daemon already refused a cancelled read")
        #expect(h.broker.openRequests.isEmpty)
    }

    /// The service is gone: no dialog opens and nothing is answered.
    @Test func noPlacementShowsNothing() {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        let ask = TerminalClipboardReadService.dialogAsk(center: center) { _ in nil }
        var answers: [Bool] = []
        let close = ask(ClipboardReadPrompt(requestID: "r1", terminalID: Self.terminal, location: .standard,
                                            host: ClipboardReadHost(kind: .local))) { answers.append($0) }
        close()
        #expect(center.records.isEmpty && answers.isEmpty)
    }
}
