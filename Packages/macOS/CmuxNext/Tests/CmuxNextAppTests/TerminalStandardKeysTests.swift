import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// The standard macOS terminal keys (Lawrence 2026-10-06, after decision K1): in a focused
/// terminal they behave as in Ghostty and the shipping cmux. Cmd-K clears through the catalog's
/// Clear Screen and Scrollback; the keys cmux has no terminal action for reach the terminal, where
/// Ghostty's own defaults run (font size of this terminal, previous match, jump to prompt, line
/// start/end, delete to line start, scroll to top/bottom, word moves).
@MainActor
struct TerminalStandardKeysTests {
    typealias K = KeyInterceptionTests
    typealias M = KeyOwnershipMatrixTests

    private func owner(_ event: NSEvent, _ focus: FocusState) -> KeyOwner {
        M.owner(ActionBindingCoverageTests.boundServices(), event, M.Surface(name: "", focus: focus))
    }

    static var agent: FocusState { M.focused(.agent, tab: "a1") }

    @Test func cmuxActionsRunTheirTerminalBehavior() throws {
        #expect(owner(try K.key("k", keyCode: 40, [.command]), M.terminal) == .action("terminal.clear"))
        #expect(owner(try K.key("f", keyCode: 3, [.command]), M.terminal) == .action("find"))
        #expect(owner(try K.key("g", keyCode: 5, [.command]), M.terminal) == .action("findNext"))
    }

    @Test func ghosttyDefaultsGetTheKeyInAFocusedTerminal() throws {
        let keys: [(String, NSEvent)] = [
            ("Cmd-= (this terminal's font size)", try K.key("=", keyCode: 24, [.command])),
            ("Cmd-- (this terminal's font size)", try K.key("-", keyCode: 27, [.command])),
            ("Cmd-0 (this terminal's font size)", try K.key("0", keyCode: 29, [.command])),
            ("Cmd-Shift-G (previous match)", try K.key("G", keyCode: 5, [.command, .shift])),
            ("Cmd-Up (previous prompt)", try K.key(String(UnicodeScalar(NSUpArrowFunctionKey)!), keyCode: 126, [.command])),
            ("Cmd-Down (next prompt)", try K.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125, [.command])),
            ("Cmd-Left (line start)", try K.key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), keyCode: 123, [.command])),
            ("Cmd-Right (line end)", try K.key(String(UnicodeScalar(NSRightArrowFunctionKey)!), keyCode: 124, [.command])),
            ("Cmd-Backspace (delete to line start)", try K.key("\u{7F}", keyCode: 51, [.command])),
            ("Cmd-Home (scroll to top)", try K.key(String(UnicodeScalar(NSHomeFunctionKey)!), keyCode: 115, [.command])),
            ("Cmd-End (scroll to bottom)", try K.key(String(UnicodeScalar(NSEndFunctionKey)!), keyCode: 119, [.command])),
            ("Option-Left (word back)", try K.key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), keyCode: 123, [.option])),
            ("Option-Right (word forward)", try K.key(String(UnicodeScalar(NSRightArrowFunctionKey)!), keyCode: 124, [.option])),
        ]
        for (name, event) in keys {
            #expect(owner(event, M.terminal) == .surface, "\(name) must reach the terminal")
        }
    }

    /// Outside a terminal the same chords keep their cmux meaning, and Cmd-K runs nothing.
    @Test func outsideATerminalTheChordsKeepTheirCmuxMeaning() throws {
        #expect(owner(try K.key("=", keyCode: 24, [.command]), Self.agent) == .action("increaseWorkspaceTerminalFontSize"))
        // Cmd-Shift-G's grouping needs a workspace selection this harness has no store for; the live
        // check (scripts/cmux-next/terminal-keys-e2e.py) covers it in a real window.
        if case .action(let id) = owner(try K.key("k", keyCode: 40, [.command]), Self.agent) {
            Issue.record("Cmd-K ran \(id) in an agent chat")
        }
    }
}
