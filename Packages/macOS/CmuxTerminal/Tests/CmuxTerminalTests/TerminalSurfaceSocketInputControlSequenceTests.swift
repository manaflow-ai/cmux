import Foundation
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

@Suite struct TerminalSurfaceSocketInputControlSequenceTests {
    /// A DSR cursor-position query (`ESC[6n` / `ESC[?6n`) is consumed and
    /// answered by the emulator, so it is routed to the terminal output parser as
    /// raw bytes. This is the sequence #5763 needs the emulator to answer with a
    /// CPR.
    @Test func csiDeviceStatusReportQueryRoutesThroughTerminalParser() throws {
        for sequence in ["\u{1B}[6n", "\u{1B}[?6n", "\u{1B}[5n"] {
            let payload = try #require(singleTerminalBytePayload(for: sequence))

            #expect(payload == Data(sequence.utf8))
        }
    }

    /// A CPR *response* (`ESC[50;36R`) is a terminal-to-application reply, not a
    /// query the emulator answers. It must *not* be routed to the terminal output
    /// parser — otherwise the display parser swallows bytes the foreground program
    /// is waiting for. It stays on the input path instead.
    @Test func csiCursorPositionReportIsNotRoutedThroughTerminalParser() throws {
        let sequence = "\u{1B}[50;36R"
        let inputPath = try #require(inputPathPieces(for: sequence))

        #expect(
            !TerminalSurface.parsedSocketInputEvents(for: sequence).contains {
                if case .terminalBytes = $0 { return true } else { return false }
            },
            "A CPR response must not be fed to the display parser; it is destined for the PTY program."
        )
        #expect(inputPath.keyLabel == "escape")
        #expect(inputPath.rawPayload == Data("[50;36R".utf8))
    }

    /// A function-key CSI (`ESC[15~`, F5) is interactive input for the foreground
    /// program, not a terminal report, so it is *not* routed to the terminal
    /// output parser. Only DSR queries (`ESC[5n` / `ESC[6n`) — the sequences #5763
    /// needs the emulator to answer — are parser-routed. Routing every complete
    /// CSI there instead swallowed genuine input keys (function keys,
    /// kitty-keyboard, mouse, arbitrary `terminal.input`) as display-only control
    /// sequences, which never reached the PTY.
    @Test func csiFunctionKeySequenceIsNotRoutedThroughTerminalParser() throws {
        let sequence = "\u{1B}[15~"
        let inputPath = try #require(inputPathPieces(for: sequence))

        #expect(
            !TerminalSurface.parsedSocketInputEvents(for: sequence).contains {
                if case .terminalBytes = $0 { return true } else { return false }
            },
            "A function-key CSI must not be fed to the display parser as terminal output."
        )
        #expect(inputPath.keyLabel == "escape")
        #expect(inputPath.rawPayload == Data("[15~".utf8))
    }

    /// A modified function key that shares the CPR `R` final (xterm Shift+F3 is
    /// `ESC[1;2R`) is interactive input, not a cursor report, so it must not be
    /// routed to the terminal output parser either — otherwise reverse-tab-style
    /// modified F-keys would be swallowed like a CPR reply.
    @Test func csiModifiedFunctionKeyIsNotRoutedThroughTerminalParser() throws {
        let sequence = "\u{1B}[1;2R"
        let inputPath = try #require(inputPathPieces(for: sequence))

        #expect(
            !TerminalSurface.parsedSocketInputEvents(for: sequence).contains {
                if case .terminalBytes = $0 { return true } else { return false }
            },
            "A modified function key ending in R must not be fed to the display parser as a CPR report."
        )
        #expect(inputPath.keyLabel == "escape")
        #expect(inputPath.rawPayload == Data("[1;2R".utf8))
    }

    /// The navigation keys cmux clients actually send (arrows, home/end, page
    /// up/down) are re-issued as key events *before* the control-sequence routing,
    /// so they reach the PTY through libghostty's cursor-key encoding instead of
    /// being consumed by the terminal parser.
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

    /// Shift+Tab (`ESC[Z`, back-tab) is re-issued as a Shift+Tab key event and
    /// reaches the PTY through libghostty's key encoding (which emits `ESC[Z`)
    /// instead of being consumed by the terminal parser as cursor-backward-tab. It
    /// is the raw-bytes sibling of the `backtab` named key in `pendingKeyEvent(for:)`,
    /// and the one interactive CSI the iOS client actually sends over the socket.
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

    private func inputPathPieces(for text: String) -> (keyLabel: String, rawPayload: Data)? {
        let events = TerminalSurface.parsedSocketInputEvents(for: text)
        guard events.count == 2 else { return nil }
        guard case .key(let event) = events[0] else { return nil }
        guard case .rawBytes(let payload) = events[1] else { return nil }
        return (event.label, payload)
    }
}
