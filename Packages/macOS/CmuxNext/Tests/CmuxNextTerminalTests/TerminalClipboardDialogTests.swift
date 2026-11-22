@testable import CmuxNextTerminal
import CmuxNextDesign
import Testing

/// R96: an unsafe paste or an OSC 52 request asks in a cmux dialog that
/// blocks only its terminal. Escape denies and the text shows. Allow has no
/// key: a Return typed into the terminal as the dialog opens must never
/// paste or hand over the clipboard (the clipboard-read broker's rule).
@MainActor
struct TerminalClipboardDialogTests {
    @Test func returnDoesNothingEscapeDeniesAndTheTextShows() {
        let spec = TerminalClipboardRequests.spec("Paste?", "Line breaks.", preview: "rm -rf build\nmake")
        #expect(spec.defaultButton == nil, "Allow is never the default button")
        #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: spec) == nil)
        #expect(CmuxDialogKeys.action(for: .return, modifiers: .command, in: spec) == nil)
        #expect(CmuxDialogKeys.action(for: .escape, modifiers: [], in: spec) == .press("deny"))
        #expect(spec.fields == [.preview("rm -rf build\nmake")])
    }

    /// Through the dialog itself: Return leaves the question open, Escape
    /// answers Deny.
    @Test func aTypedReturnLeavesTheQuestionOpen() throws {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var answers: [String] = []
        let id = center.present(TerminalClipboardRequests.spec("Read?", "OSC 52.", preview: "secret"), in: .app) {
            answers.append($0.button)
        }
        #expect(!center.key(.return, in: id))
        #expect(answers.isEmpty && center.records.count == 1)
        #expect(center.key(.escape, in: id))
        #expect(answers == ["deny"] && center.records.isEmpty)
    }

    @Test func aLongPasteShowsOnlyItsStart() {
        let spec = TerminalClipboardRequests.spec("Paste?", "Line breaks.", preview: String(repeating: "x", count: 5_000))
        guard case .preview(let text)? = spec.fields.first else {
            Issue.record("no preview")
            return
        }
        #expect(text.count == 2_001 && text.hasSuffix("…"))
    }
}

/// A closed terminal ends its clipboard question with Deny.
@MainActor
struct TerminalClipboardDialogLifetimeTests {
    @Test func aClosedTerminalAnswersDeny() {
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        var answer: CmuxDialogAnswer?
        let id = center.present(TerminalClipboardRequests.spec("Paste?", "Line breaks.", preview: "ls"), in: .app) { answer = $0 }
        center.dismiss(id)
        #expect(answer?.button == "deny")
    }
}
