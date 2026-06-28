import Carbon.HIToolbox
import CmuxTerminalCore
import GhosttyKit
import Testing

@testable import CmuxTerminal

/// Covers the meta (Option-modified) escape sequences the iOS app sends over the
/// socket-input grammar. The iPad encodes Option+<key> as `ESC<byte>`; the parser
/// must collapse each into a single Alt+<key> press so libghostty re-encodes it
/// atomically, instead of leaking a stray Escape press plus the trailing byte as
/// literal text (the on-device word-jump / Option+Enter bug).
@Suite("Socket input meta escape parsing")
struct TerminalSurfaceSocketInputEscapeTests {
    private static func keyEvent(_ input: ParsedSocketInput) -> PendingKeyEvent? {
        guard case let .key(event) = input else { return nil }
        return event
    }

    /// Parses `text` and returns its single key event, or nil when the parse did
    /// not collapse to exactly one key press (e.g. the buggy Escape + literal).
    private func soleKey(_ text: String) -> PendingKeyEvent? {
        let events = TerminalSurface.parsedSocketInputEvents(for: text)
        guard events.count == 1 else { return nil }
        return events.first.flatMap(Self.keyEvent)
    }

    @Test("ESC b (Option+Left word-jump) becomes Alt+B, not Escape + literal b")
    func metaBWordJumpBack() throws {
        let event = try #require(soleKey("\u{1B}b"))
        #expect(event.keycode == UInt32(kVK_ANSI_B))
        #expect(event.mods.rawValue == GHOSTTY_MODS_ALT.rawValue)
    }

    @Test("ESC f (Option+Right word-jump) becomes Alt+F, not Escape + literal f")
    func metaFWordJumpForward() throws {
        let event = try #require(soleKey("\u{1B}f"))
        #expect(event.keycode == UInt32(kVK_ANSI_F))
        #expect(event.mods.rawValue == GHOSTTY_MODS_ALT.rawValue)
    }

    @Test("ESC CR (Option+Enter) becomes Alt+Return")
    func metaReturnCarriageReturn() throws {
        let event = try #require(soleKey("\u{1B}\r"))
        #expect(event.keycode == UInt32(kVK_Return))
        #expect(event.mods.rawValue == GHOSTTY_MODS_ALT.rawValue)
    }

    @Test("ESC LF (Option+Enter) also becomes Alt+Return")
    func metaReturnLineFeed() throws {
        let event = try #require(soleKey("\u{1B}\n"))
        #expect(event.keycode == UInt32(kVK_Return))
        #expect(event.mods.rawValue == GHOSTTY_MODS_ALT.rawValue)
    }

    @Test("ESC 5 (Option+5) becomes Alt+5")
    func metaDigitFive() throws {
        let event = try #require(soleKey("\u{1B}5"))
        #expect(event.keycode == UInt32(kVK_ANSI_5))
        #expect(event.mods.rawValue == GHOSTTY_MODS_ALT.rawValue)
    }

    // MARK: - Regression guards for the pre-existing escape handling

    @Test("CSI left arrow (ESC [ D) stays a single unmodified arrow key")
    func csiLeftArrowUnchanged() throws {
        let event = try #require(soleKey("\u{1B}[D"))
        #expect(event.keycode == UInt32(kVK_LeftArrow))
        #expect(event.mods.rawValue == GHOSTTY_MODS_NONE.rawValue)
    }

    @Test("Meta+Backspace (ESC DEL) stays Backspace with the Option modifier")
    func metaBackspaceUnchanged() throws {
        let event = try #require(soleKey("\u{1B}\u{7F}"))
        #expect(event.keycode == UInt32(kVK_Delete))
        #expect(event.mods.rawValue == GHOSTTY_MODS_ALT.rawValue)
    }

    @Test("SS3 cursor key (ESC O A) stays an arrow, not swallowed as Alt+O")
    func ss3CursorKeyPreserved() throws {
        let event = try #require(soleKey("\u{1B}OA"))
        #expect(event.keycode == UInt32(kVK_UpArrow))
        #expect(event.mods.rawValue == GHOSTTY_MODS_NONE.rawValue)
    }

    @Test("DCS string control (ESC P … ST) stays a terminal-byte sequence, not Alt+P")
    func dcsStringControlPreserved() {
        let events = TerminalSurface.parsedSocketInputEvents(for: "\u{1B}Pq\u{1B}\\")
        #expect(events.count == 1)
        guard case .terminalBytes = events.first else {
            Issue.record("expected a single .terminalBytes event, got \(events)")
            return
        }
    }
}
