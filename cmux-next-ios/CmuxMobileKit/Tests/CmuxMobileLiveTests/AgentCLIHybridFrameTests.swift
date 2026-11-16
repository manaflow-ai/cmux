import Foundation
import Testing
@testable import CmuxMobileLive

/// `agent-cli-frame` events (`agent-cli-hybrid-v1`): the phone draws an agent CLI's changed
/// cells with the same terminal bytes as cmux-tui's `cmux_agent_cli_render::vt::frame_bytes`,
/// so its Terminal face looks as it does from the PTY.
@MainActor @Suite struct AgentCLIHybridFrameTests {
    private func line(_ object: [String: Any]) -> Data { FakeTerminalDaemon.line(object) }

    /// cmux-tui's `vt::tests::a_keyframe_clears_then_writes_its_cells_in_their_style`: "hi" at
    /// row 0, column 2 in palette 174 and bold, then 3 cells of row 1 cleared.
    private let keyframeData = Data([0, 0, 0, 2, 0, 2, 5, 1, 174, 0, 1, 0x68, 0x69, 1, 0, 6])

    private func event(frame: Int, base: Int?, data: Data, cursor: (Int, Int, Bool) = (1, 3, true)) -> [String: Any] {
        var object: [String: Any] = [
            "event": "agent-cli-frame", "surface": 7, "stream": "s1", "frame": frame,
            "cols": 20, "rows": 4, "data": data.base64EncodedString(),
            "cursor_x": cursor.0, "cursor_y": cursor.1, "cursor_visible": cursor.2,
        ]
        if let base { object["base"] = base }
        return object
    }

    @Test func aKeyframeDrawsTheBytesTheDaemonsTestExpects() throws {
        let frame = try #require(AgentCLIHybridFrame(event(frame: 1, base: nil, data: keyframeData)))
        let bytes = try #require(frame.terminalBytes)
        #expect(String(decoding: bytes, as: UTF8.self)
            == "\u{1b}[?2026h\u{1b}[?25l\u{1b}[0m\u{1b}[H\u{1b}[2J\u{1b}[1;3H\u{1b}[0;1;38;5;174mhi\u{1b}[0m"
            + "\u{1b}[2;1H\u{1b}[3X\u{1b}[0m\u{1b}[4;2H\u{1b}[?25h\u{1b}[?2026l")
    }

    @Test func aScrollUpIsLineFeedsOnTheLastRow() throws {
        // shift 2 (zigzag 4), no spans.
        let frame = try #require(AgentCLIHybridFrame(event(frame: 2, base: 1, data: Data([0, 0, 4, 0]), cursor: (0, 0, false))))
        let text = String(decoding: try #require(frame.terminalBytes), as: UTF8.self)
        #expect(text.contains("\u{1b}[4;1H\n\n"))
        #expect(!text.contains("\u{1b}[2J"))
        #expect(!text.contains("\u{1b}[?25h"), "a hidden cursor stays hidden")
    }

    @Test func wideGlyphsAndColorsDecode() throws {
        // One span: "界" then its empty trailing cell, rgb fg, palette 9 bg, underline (0x100, varint 0x80 0x02).
        var data = Data([0, 0, 0, 1, 0, 0, 5, 2, 1, 2, 3, 1, 9, 0x80, 0x02])
        data.append(contentsOf: [1, 3] + Array("界".utf8) + [2])
        let delta = try #require(AgentCLIHybridFrame.Delta(data))
        let style = AgentCLIHybridFrame.Style(fg: .rgb(1, 2, 3), bg: .palette(9), attrs: 0x100)
        #expect(delta.spans == [.set(row: 0, column: 0, cells: [.init(text: "界", style: style), .init(text: "", style: style)])])
        #expect(style.sgr == "\u{1b}[0;4;38;2;1;2;3;101m")
        let frame = try #require(AgentCLIHybridFrame(event(frame: 1, base: nil, data: data)))
        let text = String(decoding: try #require(frame.terminalBytes), as: UTF8.self)
        #expect(text.contains("\u{1b}[1;1H\u{1b}[0;4;38;2;1;2;3;101m界\u{1b}[0m"), "no blank after a wide glyph")
    }

    @Test func truncatedOrTrailingBytesAreNotADelta() {
        #expect(AgentCLIHybridFrame.Delta(keyframeData.dropLast()) == nil)
        #expect(AgentCLIHybridFrame.Delta(keyframeData + Data([0])) == nil)
    }

    @Test func theParserDrawsFramesIntoTheMirror() throws {
        var parser = DaemonTerminalEventParser(surface: 7)
        let first = parser.parse(line(event(frame: 1, base: nil, data: keyframeData)))
        let keyBytes = try #require(AgentCLIHybridFrame(event(frame: 1, base: nil, data: keyframeData))?.terminalBytes)
        #expect(first == [.columns(20), .rows(4), .historyRowsOmitted(0), .alternateScreen(false),
                          .output(keyBytes), .hybridFrame(stream: "s1", frame: 1, resumed: false)])
        // A delta on the same grid: only its bytes.
        let next = parser.parse(line(event(frame: 2, base: 1, data: Data([0, 0, 0, 0]))))
        #expect(next.count == 2)
        #expect(next.last == .hybridFrame(stream: "s1", frame: 2, resumed: false))
        // A later keyframe (after a resize) starts the mirror over.
        let again = parser.parse(line(event(frame: 3, base: nil, data: keyframeData)))
        #expect(again.prefix(3) == [.columns(20), .rows(4), .resetMirror(alternate: false)])
    }

    @Test func aResumedAttachsFirstFrameKeepsTheScreen() {
        var parser = DaemonTerminalEventParser(surface: 7)
        let events = parser.parse(line(event(frame: 9, base: 5, data: Data([0, 0, 0, 0]))))
        #expect(events.last == .hybridFrame(stream: "s1", frame: 9, resumed: true))
        #expect(!events.contains(.historyRowsOmitted(0)))
    }

    @Test func theCapabilityFollowsTheSetting() throws {
        #expect(!DaemonTerminalSession.capabilities(agentCLIHybrid: false).contains("agent-cli-hybrid-v1"))
        #expect(DaemonTerminalSession.capabilities(agentCLIHybrid: true).contains("agent-cli-hybrid-v1"))
        let defaults = try #require(UserDefaults(suiteName: "AgentCLIHybridFrameTests-\(UUID().uuidString)"))
        #expect(!DaemonTerminalSession.agentCLIHybridEnabled(defaults), "off by default")
        defaults.set(true, forKey: DaemonTerminalSession.agentCLIHybridDefaultsKey)
        #expect(DaemonTerminalSession.agentCLIHybridEnabled(defaults))
    }
}
