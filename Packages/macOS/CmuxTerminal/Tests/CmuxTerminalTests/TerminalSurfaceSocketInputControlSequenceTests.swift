import Foundation
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

@Suite struct TerminalSurfaceSocketInputControlSequenceTests {
    @Test func csiDeviceStatusReportQueryRoutesThroughTerminalParser() throws {
        let sequence = "\u{1B}[6n"
        let payload = try #require(singleTerminalBytePayload(for: sequence))

        #expect(payload == Data(sequence.utf8))
    }

    @Test func csiCursorPositionReportRoutesThroughTerminalParser() throws {
        let sequence = "\u{1B}[50;36R"
        let payload = try #require(singleTerminalBytePayload(for: sequence))

        #expect(payload == Data(sequence.utf8))
    }

    /// A function-key CSI (`ESC[15~`, F5) is interactive input for the foreground
    /// program, not a terminal report, so it is *not* routed to the terminal
    /// output parser. Only cursor reports/queries (DSR `ESC[…n` / CPR `ESC[…R`) —
    /// the sequences #5763 needs the emulator to answer — are parser-routed.
    /// Routing every complete CSI there instead swallowed genuine input keys
    /// (function keys, kitty-keyboard, mouse, arbitrary `terminal.input`) as
    /// display-only control sequences, which never reached the PTY.
    @Test func csiFunctionKeySequenceIsNotRoutedThroughTerminalParser() {
        let events = TerminalSurface.parsedSocketInputEvents(for: "\u{1B}[15~")

        #expect(
            !events.contains { if case .terminalBytes = $0 { return true } else { return false } },
            "A function-key CSI must not be fed to the display parser as terminal output."
        )
    }

    /// The navigation keys cmux clients actually send over the socket (arrows,
    /// home/end, page up/down) are re-issued as key events *before* the
    /// control-sequence routing, so they reach the PTY through libghostty's
    /// cursor-key encoding instead of being consumed by the terminal parser.
    /// This guard is why routing complete CSI sequences to the parser does not
    /// regress interactive navigation input.
    @Test func navigationArrowRoutesAsKeyEventNotTerminalParser() throws {
        let key = try #require(singleKeyEvent(for: "\u{1B}[A"))

        #expect(key.label == "up")
    }

    /// A single-digit CSI tilde navigation key (`ESC[5~`, Page Up) is also
    /// re-issued as a key event rather than routed to the terminal parser,
    /// distinguishing it from the multi-digit function-key form above.
    @Test func navigationPageUpTildeRoutesAsKeyEventNotTerminalParser() throws {
        let key = try #require(singleKeyEvent(for: "\u{1B}[5~"))

        #expect(key.label == "pageUp")
    }

    /// Shift+Tab (`ESC[Z`, back-tab) is an *interactive key*, not a terminal
    /// report, so it is re-issued as a Shift+Tab key event and reaches the PTY
    /// through libghostty's key encoding (which emits `ESC[Z`) instead of being
    /// consumed by the terminal parser as cursor-backward-tab (a display-only
    /// move). It is the raw-bytes sibling of the `backtab` named key in
    /// `pendingKeyEvent(for:)`, and the one interactive CSI the iOS client
    /// actually sends over the socket (a hardware Shift+Tab and the on-screen
    /// ⇧+Tab accessory), so routing it to the parser would swallow reverse-focus
    /// in TUIs like Claude Code.
    @Test func shiftTabBackTabRoutesAsKeyEventNotTerminalParser() throws {
        let key = try #require(singleKeyEvent(for: "\u{1B}[Z"))

        #expect(key.label == "backTab")
    }

    private func singleTerminalBytePayload(for text: String) -> Data? {
        let events = TerminalSurface.parsedSocketInputEvents(for: text)
        guard events.count == 1 else { return nil }
        guard case .terminalBytes(let payload) = events[0] else { return nil }
        return payload
    }

    private func singleKeyEvent(for text: String) -> PendingKeyEvent? {
        let events = TerminalSurface.parsedSocketInputEvents(for: text)
        guard events.count == 1 else { return nil }
        guard case .key(let event) = events[0] else { return nil }
        return event
    }
}
