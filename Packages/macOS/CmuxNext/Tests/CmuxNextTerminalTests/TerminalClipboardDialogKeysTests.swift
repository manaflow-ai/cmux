import CmuxNextDesign
@testable import CmuxNextTerminal
import Testing

/// QA chrome-parity-v2-1 (journey paste-confirm-keys): Cmd-V of a multi-line text into a program
/// asks "Paste into the terminal?", and Return did nothing (Allow had no key), so a person who
/// confirms dialogs with Return could not paste. The person's own paste follows the dialog
/// keyboard (`CmuxDialogKeys`), as Ghostty's paste confirmation does: Return pastes, Escape
/// denies. A program's OSC 52 request still has no Return key: the program, not the person,
/// picks the moment it opens, so a Return typed for the terminal must not hand the clipboard over.
@Suite struct TerminalClipboardDialogKeysTests {
    private static let text = "L1\nL2\n"

    @Test func returnPastesAndEscapeDeniesAMultiLinePaste() {
        let spec = TerminalClipboardRequests.spec(for: .paste, preview: Self.text)
        #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: spec) == .press("allow"))
        #expect(CmuxDialogKeys.action(for: .escape, modifiers: [], in: spec) == .press("deny"))
        let allow = spec.buttons.first { $0.id == "allow" }
        #expect(allow.flatMap { CmuxDialogKeys.hint(for: $0, in: spec) } == .return, "Allow shows no Return keycap")
        #expect(spec.identifier == "cmux.dialog.terminalClipboard")
    }

    @Test(arguments: [TerminalClipboardRequestKind.osc52Read, .osc52Write])
    func aProgramsClipboardRequestHasNoReturnKey(_ kind: TerminalClipboardRequestKind) {
        let spec = TerminalClipboardRequests.spec(for: kind, preview: Self.text)
        #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: spec) == nil)
        #expect(CmuxDialogKeys.action(for: .escape, modifiers: [], in: spec) == .press("deny"))
    }
}
