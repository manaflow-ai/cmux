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
        // The empty cell first, then the glyph over it: Ghostty decides whether 界 covers it
        // (cmux-tui `vt::tests::a_wide_glyph_never_depends_on_a_width_table`).
        #expect(text.contains("\u{1b}[1;1H\u{1b}[1;2H\u{1b}[0;4;38;2;1;2;3;101m \u{1b}[1;1H界\u{1b}[0m"), "\(text)")
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
        // A later keyframe at the same grid (the program switched screens) clears and draws
        // the screen: no reset, so the scrollback stays.
        let same = parser.parse(line(event(frame: 3, base: nil, data: keyframeData)))
        #expect(same == [.columns(20), .rows(4), .output(keyBytes), .hybridFrame(stream: "s1", frame: 3, resumed: false)])
        // A keyframe after a resize starts the mirror over.
        var resized = event(frame: 4, base: nil, data: keyframeData)
        resized["cols"] = 30
        let again = parser.parse(line(resized))
        #expect(again.prefix(3) == [.columns(30), .rows(4), .resetMirror(alternate: false)])
    }

    /// Frames carry cells, not modes: the daemon says the alternate screen (Codex, opencode)
    /// and the input modes as `output` bytes, and a keyframe keeps them. One after a resize
    /// resets the mirror, which clears them, so it puts them back before it draws (#44052 F1).
    @Test func keyframesKeepTheAlternateScreenAndInputModes() throws {
        var parser = DaemonTerminalEventParser(surface: 7)
        let modes = line(["event": "output", "surface": 7,
                          "data": Data("\u{1b}[?1049h\u{1b}[?2004h\u{1b}[?1h".utf8).base64EncodedString()])
        #expect(parser.parse(modes).contains(.alternateScreen(true)))
        let first = parser.parse(line(event(frame: 1, base: nil, data: keyframeData)))
        #expect(first.contains(.alternateScreen(true)), "\(first)")
        #expect(!first.contains(.alternateScreen(false)), "the keyframe left the alternate screen: \(first)")

        var resized = event(frame: 2, base: nil, data: keyframeData)
        resized["cols"] = 30
        let again = parser.parse(line(resized))
        let keyBytes = try #require(AgentCLIHybridFrame(resized)?.terminalBytes)
        #expect(again == [.columns(30), .rows(4), .resetMirror(alternate: true),
                          .output(Data("\u{1b}[?1049h\u{1b}[?1h\u{1b}[?2004h".utf8)),
                          .output(keyBytes), .hybridFrame(stream: "s1", frame: 2, resumed: false)])

        // The program leaves the alternate screen and resets its modes: a later reset puts
        // back none of them.
        let off = line(["event": "output", "surface": 7,
                        "data": Data("\u{1b}[?2004l\u{1b}[?1l\u{1b}[?1049l".utf8).base64EncodedString()])
        #expect(parser.parse(off).contains(.alternateScreen(false)))
        var smaller = event(frame: 3, base: nil, data: keyframeData)
        smaller["cols"] = 25
        let last = parser.parse(line(smaller))
        #expect(last.prefix(3) == [.columns(25), .rows(4), .resetMirror(alternate: false)])
        #expect(last.count == 5, "no modes to put back: \(last)")
    }


    /// A varint past 64 bits is not a delta: the shift used to drop its high bits and read a
    /// smaller value, drawing a wrong frame instead of falling back (#44052 F2).
    @Test func aVarintPast64BitsIsNotADelta() {
        // seq, then at_ms 0, shift 0 and no spans.
        func withSeq(_ seq: [UInt8]) -> Data { Data(seq + [0, 0, 0]) }
        #expect(AgentCLIHybridFrame.Delta(withSeq(Array(repeating: 0xFF, count: 9) + [0x01]))?.seq == UInt64.max)
        #expect(AgentCLIHybridFrame.Delta(withSeq(Array(repeating: 0x80, count: 9) + [0x02])) == nil, "bit 64")
        #expect(AgentCLIHybridFrame.Delta(withSeq(Array(repeating: 0x80, count: 10) + [0x00])) == nil, "an eleventh byte")
        // A row past UInt16 (the width the grid is read in): one span, row 65536.
        #expect(AgentCLIHybridFrame.Delta(Data([0, 0, 0, 1, 0x80, 0x80, 0x04, 0, 2])) == nil, "a row past UInt16")
        // A lean frame reads the same varints: a numbered keyframe whose number overflows.
        var decoder = AgentCLIHybridLeanDecoder()
        var lean = [UInt8](leanKeyframe)
        lean.replaceSubrange(6...6, with: Array(repeating: 0x80, count: 9) + [0x02])
        #expect(decoder.decode(Data(lean)) == nil, "a lean frame number past 64 bits")
    }

    @Test func aResumedAttachsFirstFrameKeepsTheScreen() {
        var parser = DaemonTerminalEventParser(surface: 7, hybridResume: (stream: "s1", frame: 5))
        let events = parser.parse(line(event(frame: 9, base: 5, data: Data([0, 0, 0, 0]))))
        #expect(events.last == .hybridFrame(stream: "s1", frame: 9, resumed: true))
        #expect(!events.contains(.historyRowsOmitted(0)))
    }

    @Test func theCapabilityFollowsTheSetting() throws {
        #expect(!DaemonTerminalSession.capabilities(agentCLIHybrid: false).contains("agent-cli-hybrid-v1"))
        #expect(DaemonTerminalSession.capabilities(agentCLIHybrid: true).contains("agent-cli-hybrid-v1"))
        #expect(DaemonTerminalSession.capabilities(agentCLIHybrid: true).contains("agent-cli-hybrid-v2"))
        #expect(!DaemonTerminalSession.capabilities(agentCLIHybrid: false).contains("agent-cli-hybrid-v2"))
        let defaults = try #require(UserDefaults(suiteName: "AgentCLIHybridFrameTests-\(UUID().uuidString)"))
        #expect(!DaemonTerminalSession.agentCLIHybridEnabled(defaults), "off by default")
        defaults.set(true, forKey: DaemonTerminalSession.agentCLIHybridDefaultsKey)
        #expect(DaemonTerminalSession.agentCLIHybridEnabled(defaults))
    }

    // MARK: lean frames (`agent-cli-lean`, `agent-cli-hybrid-v2`)

    /// The keyframe above as cmux-tui's `LeanEncoder` packs it for stream "s1" (20x4, cursor
    /// 1,3 shown): flags 31 (keyframe, head, numbered, cursor, cursor shown), the head, frame 1,
    /// the cursor, then the spans with the style as table entry 0 (palette 174, default, bold).
    private let leanKeyframe = Data([31, 2, 0x73, 0x31, 20, 4, 1, 1, 3, 0, 2, 0, 2, 5, 0, 1, 174, 0, 1, 0x68, 0x69, 1, 0, 6])

    private func leanLine(_ bytes: Data) -> Data {
        line(["event": "agent-cli-lean", "surface": 7, "f": bytes.base64EncodedString()])
    }

    @Test func aLeanKeyframeDrawsWhatItsV1TwinDraws() throws {
        var decoder = AgentCLIHybridLeanDecoder()
        let decoded = decoder.decode(leanKeyframe)
        let lean = try #require(decoded)
        let v1 = try #require(AgentCLIHybridFrame(event(frame: 1, base: nil, data: keyframeData)))
        #expect(lean == v1)
        #expect(lean.terminalBytes == v1.terminalBytes)
    }

    @Test func aFollowingLeanFrameIsNumberedByTheOneBefore() throws {
        var decoder = AgentCLIHybridLeanDecoder()
        let keyframe = decoder.decode(leanKeyframe)
        #expect(keyframe != nil)
        // Flags 16 (cursor shown, unmoved), no shift, one span: row 2, 5 cells in style 0 as a run of "x".
        let decoded = decoder.decode(Data([16, 0, 1, 2, 0, 11, 0, 2, 5, 0x78]))
        let next = try #require(decoded)
        #expect(next.frame == 2 && next.base == 1 && next.stream == "s1")
        #expect(next.columns == 20 && next.rows == 4 && next.cursorX == 1 && next.cursorY == 3 && next.cursorVisible)
        let style = AgentCLIHybridFrame.Style(fg: .palette(174), bg: .standard, attrs: 1)
        #expect(next.delta?.spans == [.set(row: 2, column: 0, cells: Array(repeating: .init(text: "x", style: style), count: 5))])
    }

    @Test func aBadLeanFrameLeavesTheDecoderAsItWas() throws {
        var decoder = AgentCLIHybridLeanDecoder()
        let orphan = decoder.decode(Data([16, 0, 0]))
        #expect(orphan == nil, "no frame to follow yet")
        let keyframe = decoder.decode(leanKeyframe)
        #expect(keyframe != nil)
        // Style 1 is not in the table yet and brings none: refused, frame 2 still follows 1.
        let unknownStyle = decoder.decode(Data([16, 0, 1, 0, 0, 3, 1]))
        #expect(unknownStyle == nil)
        let trailing = decoder.decode(leanKeyframe + Data([0]))
        #expect(trailing == nil, "trailing bytes")
        let next = decoder.decode(Data([16, 0, 0]))
        #expect(next?.frame == 2)
    }

    @Test func theParserDrawsLeanFramesLikeV1Ones() throws {
        var lean = DaemonTerminalEventParser(surface: 7)
        var v1 = DaemonTerminalEventParser(surface: 7)
        let leanFirst = lean.parse(leanLine(leanKeyframe))
        let v1First = v1.parse(line(event(frame: 1, base: nil, data: keyframeData)))
        #expect(leanFirst == v1First && !leanFirst.isEmpty)
        let leanNext = lean.parse(leanLine(Data([16, 0, 0])))
        let v1Next = v1.parse(line(event(frame: 2, base: 1, data: Data([0, 0, 0, 0]))))
        #expect(leanNext == v1Next && !leanNext.isEmpty)
    }

    /// Every lean frame of a recorded Claude Code session (cmux-tui's
    /// `export_sessions_for_the_phone_bench`) reads back as the `agent-cli-frame` it packs.
    @Test func aRecordedSessionsLeanFramesMatchItsFrames() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("verify/agent-cli-hybrid/claude-code-2.1.310.json")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let attach = try #require(root["attach"] as? [String: Any])
        let first = try #require(attach["hybrid"] as? [String: Any])
        let firstNumber = try #require(first["frame"] as? Int)
        let frames = try #require(root["frames"] as? [[Any]]).compactMap { $0.last as? [String: Any] }
            .filter { ($0["frame"] as? Int ?? 0) > firstNumber }
        let leanEvents = try #require(root["lean_frames"] as? [[Any]]).compactMap { $0.last as? [String: Any] }
        let v1 = [first] + frames
        let lean = [try #require(attach["lean"] as? [String: Any])] + leanEvents
        #expect(v1.count == lean.count && v1.count > 50)
        var decoder = AgentCLIHybridLeanDecoder()
        for (frame, packed) in zip(v1, lean) {
            let bytes = try #require((packed["f"] as? String).flatMap { Data(base64Encoded: $0) })
            let read = decoder.decode(bytes)
            let decoded = try #require(read)
            let expected = try #require(AgentCLIHybridFrame(frame))
            #expect(decoded.stream == expected.stream && decoded.frame == expected.frame && decoded.base == expected.base)
            #expect(decoded.terminalBytes == expected.terminalBytes, "frame \(expected.frame)")
        }
    }

    /// cmux-tui's `vt::tests::a_wide_glyph_never_depends_on_a_width_table`, byte for byte: a
    /// glyph that is not ASCII never leaves the next cell where a width table guessed.
    @Test func aWideGlyphNeverDependsOnAWidthTable() throws {
        let style = AgentCLIHybridFrame.Style(fg: .rgb(1, 2, 3), bg: .palette(9), attrs: 0x100)
        let cells = ["\u{1F680}", "", "a", "\u{E9}", "b"].map { AgentCLIHybridFrame.Cell(text: $0, style: style) }
        let frame = AgentCLIHybridFrame(stream: "s1", frame: 1, base: nil, columns: 20, rows: 4,
                                        delta: .init(shift: 0, spans: [.set(row: 0, column: 0, cells: cells)]),
                                        cursorX: 0, cursorY: 0, cursorVisible: false)
        let text = String(decoding: try #require(frame.terminalBytes), as: UTF8.self)
        #expect(text == "\u{1b}[?2026h\u{1b}[?25l\u{1b}[0m\u{1b}[H\u{1b}[2J\u{1b}[1;1H\u{1b}[1;2H\u{1b}[0;4;38;2;1;2;3;101m "
            + "\u{1b}[1;1H\u{1F680}\u{1b}[1;3Ha\u{E9}\u{1b}[1;5Hb\u{1b}[0m\u{1b}[1;1H\u{1b}[?2026l")
    }
}
