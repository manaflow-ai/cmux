import Foundation
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

@Suite struct TerminalSurfaceSocketInputParserTests {
    @Test func osc11AndCPRRepliesStayTerminalBytes() {
        let firstOSC11 = "\u{1B}]11;rgb:1e1e/1e1e/1e1e\u{1B}\\"
        let firstCPR = "\u{1B}[50;1R"
        let secondOSC11 = "\u{1B}]11;rgb:1e1e/1e1e/1e1e\u{1B}\\"
        let secondCPR = "\u{1B}[50;36R"
        let events = TerminalSurface.parsedSocketInputEvents(for: firstOSC11 + firstCPR + secondOSC11 + secondCPR)
        #expect(terminalBytePayloads(in: events) == [Data(firstOSC11.utf8), Data(firstCPR.utf8), Data(secondOSC11.utf8), Data(secondCPR.utf8)])
        #expect(!containsUserInputEvents(events))
    }

    @Test func terminalCSIProbeRepliesStayTerminalBytes() {
        let replies = ["\u{1B}[?1;2c", "\u{1B}[>0;95;0c", "\u{1B}[0n", "\u{1B}[?997;1n", "\u{1B}[?0u", "\u{1B}[?12;2$y", "\u{1B}[4;1$y", "\u{1B}[6;16;8t"]
        let events = TerminalSurface.parsedSocketInputEvents(for: replies.joined())
        #expect(terminalBytePayloads(in: events) == replies.map { Data($0.utf8) })
        #expect(!containsUserInputEvents(events))
    }

    @Test func keyboardProtocolKeyInputDoesNotBecomeTerminalBytes() {
        let events = TerminalSurface.parsedSocketInputEvents(for: "\u{1B}[13;2u")
        #expect(terminalBytePayloads(in: events).isEmpty)
        #expect(containsUserInputEvents(events))
    }

    /// A viewing Mac's mirror encodes keys for the mode the host program
    /// negotiated (Kitty CSI-u, modified arrows, bracketed paste). Splitting
    /// one into an Escape key plus its tail typed `[27u` into Claude Code
    /// (https://github.com/manaflow-ai/cmux/issues/21775).
    @Test(arguments: [
        "\u{1B}[27u",             // Kitty Escape
        "\u{1B}[13;2u",           // Kitty Shift+Enter
        "\u{1B}[99;5u",           // Kitty Ctrl+C
        "\u{1B}[1;5A",            // Ctrl+Up
        "\u{1B}[Z",               // Shift+Tab
        "\u{1B}[3;5~",            // Ctrl+Forward Delete
        "\u{1B}[200~hi\u{1B}[201~", // bracketed paste
    ])
    func encodedKeySequencesReachThePTYIntact(sequence: String) {
        let events = TerminalSurface.parsedSocketInputEvents(for: sequence)
        #expect(!containsKeyOrTerminalBytes(events), "\(events)")
        #expect(rawBytes(in: events) == Data(sequence.utf8))
    }

    /// X10 and UTF-8 mouse reports are `ESC [ M` plus three coordinate
    /// characters, not a CSI. Column 95 encodes as 0x7F, which the parser
    /// otherwise turns into a Backspace key.
    @Test(arguments: [
        "\u{1B}[MCVL",                 // X10 motion report
        "\u{1B}[M`+!\u{1B}[Ma+!",      // two X10 wheel notches
        "\u{1B}[M#\u{7F}!",            // X10 release at column 95
        "\u{1B}[M#\u{100}\u{80}",      // UTF-8 format, column and row past 95
    ])
    func legacyMouseReportsReachThePTYIntact(sequence: String) {
        let events = TerminalSurface.parsedSocketInputEvents(for: sequence)
        #expect(!containsKeyOrTerminalBytes(events), "\(events)")
        #expect(rawBytes(in: events) == Data(sequence.utf8))
    }

    @Test func bareEscapeStaysTheEscapeKey() {
        let events = TerminalSurface.parsedSocketInputEvents(for: "\u{1B}")
        #expect(containsKeyOrTerminalBytes(events))
        #expect(rawBytes(in: events).isEmpty)
    }

    /// `ESC O` then text is Escape, then the text (vim's "open line above").
    @Test func escapeThenCapitalOStaysTheEscapeKey() {
        let events = TerminalSurface.parsedSocketInputEvents(for: "\u{1B}Ofix")
        guard case .key(let key) = events.first else {
            Issue.record("Expected the Escape key first: \(events)")
            return
        }
        #expect(key.label == "escape")
        #expect(rawBytes(in: events) == Data("Ofix".utf8))
    }

    @Test func c1StringRepliesStayTerminalBytes() {
        let replies = ["\u{9B}50;1R", "\u{9D}11;rgb:1e1e/1e1e/1e1e\u{9C}", "\u{98}terminal-status\u{9C}"]
        let events = TerminalSurface.parsedSocketInputEvents(for: replies.joined())
        #expect(terminalBytePayloads(in: events) == replies.map { Data($0.utf8) })
        #expect(!containsUserInputEvents(events))
    }

    @Test func sosRepliesStayTerminalBytes() {
        let reply = "\u{1B}Xterminal-status\u{1B}\\"
        let events = TerminalSurface.parsedSocketInputEvents(for: reply)
        #expect(terminalBytePayloads(in: events) == [Data(reply.utf8)])
        #expect(!containsUserInputEvents(events))
    }

    private func terminalBytePayloads(in events: [ParsedSocketInput]) -> [Data] {
        events.compactMap { if case .terminalBytes(let data) = $0 { data } else { nil } }
    }

    private func rawBytes(in events: [ParsedSocketInput]) -> Data {
        events.reduce(into: Data()) { if case .rawBytes(let data) = $1 { $0.append(data) } }
    }

    private func containsKeyOrTerminalBytes(_ events: [ParsedSocketInput]) -> Bool {
        events.contains { if case .rawBytes = $0 { false } else { true } }
    }

    private func containsUserInputEvents(_ events: [ParsedSocketInput]) -> Bool {
        events.contains { if case .terminalBytes = $0 { false } else { true } }
    }
}
