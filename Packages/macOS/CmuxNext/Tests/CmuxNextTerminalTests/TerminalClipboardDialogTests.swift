@testable import CmuxNextTerminal
import CmuxNextDesign
import Testing

/// R96: an unsafe paste or an OSC 52 request asks in a cmux dialog that
/// blocks only its terminal. Return allows, Escape denies, the text shows.
@MainActor
struct TerminalClipboardDialogTests {
    @Test func returnAllowsEscapeDeniesAndTheTextShows() {
        let spec = TerminalClipboardRequests.spec("Paste?", "Line breaks.", preview: "rm -rf build\nmake")
        #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: spec) == .press("allow"))
        #expect(CmuxDialogKeys.action(for: .escape, modifiers: [], in: spec) == .press("deny"))
        #expect(spec.fields == [.preview("rm -rf build\nmake")])
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
