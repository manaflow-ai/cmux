import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The proofs that the phone's lean decoder draws agent CLI screens right (Leo, 2026-11-16:
/// "prove it correct" / "i think we prob need more ways to prove things correct in ios").
/// Each prints one `HYBRID_PROOF` line of JSON with what it ran.
///
/// The suite is not on the main actor: the parity and fuzz proofs are tens of seconds of
/// synchronous work in a debug build, and on the main actor they held the main thread for all
/// of it, so every other main-actor test in the same `swift test` process stalled and its
/// `eventually` or deadline wait ran out (the macOS kit-test leg, ~42 s in). Only the tests
/// that drive a `DaemonTerminalSession` are `@MainActor`.
@Suite struct AgentCLIHybridProofTests {
    // MARK: 1. Parity with the reference terminal

    /// Every frame of four recorded sessions (Claude Code 2.1.310, Codex 0.164.0, opencode 1.19.5
    /// and a bash session with two resizes, scrollback, the alternate screen, wide, emoji and
    /// combined glyphs, 256-color and truecolor), through a 4 s drop and a resume on a new
    /// connection, read by the app's own parser and lean decoder: the screen its bytes draw is
    /// ghostty-vt's screen of the same PTY bytes at that frame, cell for cell (glyph, width,
    /// colors, attributes) with the cursor, and the bytes are the ones cmux-tui draws into a second
    /// ghostty-vt for the same check.
    @Test(arguments: HybridParityFixture.names)
    func everyFrameDrawsTheReferenceScreen(name: String) throws {
        #expect(!Thread.isMainThread, "the parity proof holds the main thread")
        let fixture = try #require(HybridParityFixture.load(name), "\(name): no fixture at \(HybridParityFixture.url(name).path)")
        var parser = DaemonTerminalEventParser(surface: 1)
        var decoder = AgentCLIHybridLeanDecoder()
        var connection = 0
        var shown: (stream: String, frame: Int)?
        var model: HybridScreenModel?
        var firstOfConnection = true
        var cells = 0
        var mismatched = 0
        for step in fixture.steps {
            if step.connection != connection {
                // A new connection: a new parser and lean decoder, resuming from the last frame.
                connection = step.connection
                parser = DaemonTerminalEventParser(surface: 1, hybridResume: shown)
                decoder = AgentCLIHybridLeanDecoder()
                firstOfConnection = true
            }
            let events = parser.parse(HybridWire.leanLine(step.lean))
            let label = "\(name) frame \(step.frame) (connection \(step.connection))"
            #expect(!events.contains { if case .hybridFallback = $0 { true } else { false } }, "\(label): \(events)")
            let outputs = events.compactMap { event -> Data? in
                if case .output(let bytes) = event { return bytes }
                return nil
            }
            let bytes = try #require(outputs.count == 1 ? outputs.first : nil, "\(label): \(events)")
            // cmux-tui's `vt::frame_bytes` wraps each frame in a synchronized update (DEC 2026);
            // the phone writes the same bytes without it (`AgentCLIHybridFrame.terminalBytes`).
            let syncBegin = Data("\u{1b}[?2026h".utf8), syncEnd = Data("\u{1b}[?2026l".utf8)
            #expect(step.terminalBytes.starts(with: syncBegin) && step.terminalBytes.suffix(syncEnd.count) == syncEnd,
                    "\(label): cmux-tui's bytes are no longer one synchronized update")
            let reference = Data(step.terminalBytes.dropFirst(syncBegin.count).dropLast(syncEnd.count))
            #expect(bytes == reference, "\(label): not the bytes cmux-tui checked against ghostty-vt")
            #expect(events.last == .hybridFrame(stream: fixture.stream, frame: step.frame,
                                                resumed: firstOfConnection && step.base != nil), "\(label)")
            let decodedFrame = decoder.decode(step.lean)
            let decoded = try #require(decodedFrame, "\(label)")
            let v1 = try #require(AgentCLIHybridFrame.Delta(step.delta), "\(label)")
            #expect(decoded.delta?.shift == v1.shift && decoded.delta?.spans == v1.spans, "\(label): lean and v1 differ")
            #expect(decoded.base == step.base && decoded.columns == step.columns && decoded.rows == step.rows, "\(label)")
            if step.base == nil || model == nil {
                model = HybridScreenModel(columns: step.columns, rows: step.rows, widths: fixture.widths)
            }
            model?.write(bytes)
            let screen = try #require(model)
            let differences = screen.differences(from: step.screen)
            if !differences.isEmpty { mismatched += 1 }
            #expect(differences.isEmpty, "\(label): \(differences)")
            #expect(HybridParityFixture.Cursor(x: screen.x, y: screen.y, visible: screen.cursorVisible) == step.cursor, "\(label)")
            cells += step.columns * step.rows
            shown = (fixture.stream, step.frame)
            firstOfConnection = false
        }
        let resumed = fixture.steps.filter { $0.connection > 0 }.count
        let sizes = Set(fixture.steps.map { "\($0.columns)x\($0.rows)" }).sorted()
        #expect(resumed > 0, "\(name): a resume after the drop")
        print("HYBRID_PROOF parity {\"session\":\"\(name)\",\"frames\":\(fixture.steps.count),\"cells\":\(cells),"
            + "\"framesAfterResume\":\(resumed),\"grids\":\"\(sizes.joined(separator: " "))\",\"mismatchedFrames\":\(mismatched)}")
    }

    // MARK: 2. Random frame streams

    enum Mutation: String, CaseIterable {
        // The wire can tell: the frame must fall back, never draw.
        case truncate, garbageLine, spanOutOfGrid, clearOutOfGrid, cursorOutOfGrid, shiftPastGrid, controlInCell
        // A count, place, length or style at the edge of UInt64 or Int (review F1: these trapped).
        case extremeVarint
        // v1 frames name their frame and base, so these are told too.
        case duplicate, reorder, drop, wrongBase, otherStream
        // Well-formed bytes that say something else: a lean frame that follows the last one names
        // no number, so a repeat, a swap or a lost frame, a flipped byte or garbage that happens
        // to parse cannot be told from a real frame. Counted, not asserted (see the PR).
        case flipByte, garbageFrame
    }

    struct Outcome {
        var fellBack = false
        var drewAfterFallback = false
        var wrong: String?
        var draws = 0
    }

    /// Feeds `lines` to a fresh parser of the attach `connection` and checks every frame it draws
    /// against the reference screen of the frame it says it is.
    private func run(_ lines: [Data], fixture: HybridParityFixture, connection: Int,
                     resume: (stream: String, frame: Int)?) -> Outcome {
        var parser = DaemonTerminalEventParser(surface: 1, hybridResume: resume)
        var model: HybridScreenModel
        if let resume, let base = fixture.screen(frame: resume.frame) {
            model = HybridScreenModel(step: base, widths: fixture.widths)
        } else {
            let first = fixture.steps[0]
            model = HybridScreenModel(columns: first.columns, rows: first.rows, widths: fixture.widths)
        }
        var outcome = Outcome()
        for line in lines {
            var size: (columns: Int?, rows: Int?) = (nil, nil)
            var bytes: Data?
            for event in parser.parse(line) {
                switch event {
                case .hybridFallback:
                    outcome.fellBack = true
                case .columns(let columns):
                    size.columns = columns
                case .rows(let rows):
                    size.rows = rows
                case .output(let data):
                    bytes = data
                case let .hybridFrame(stream, frame, _):
                    if outcome.fellBack { outcome.drewAfterFallback = true }
                    if let columns = size.columns, let rows = size.rows, columns != model.columns || rows != model.rows {
                        model = HybridScreenModel(columns: columns, rows: rows, widths: fixture.widths)
                    }
                    if let bytes { model.write(bytes) }
                    outcome.draws += 1
                    guard outcome.wrong == nil else { continue }
                    // Judged by its grid: a keyframe is a whole screen, so one renamed to a stream the
                    // Mac never sent still draws right when its cells are the screen at that frame.
                    guard let reference = fixture.screen(connection: connection, frame: frame) else {
                        outcome.wrong = "drew frame \(frame) of \(stream), which the Mac never sent"
                        continue
                    }
                    let differences = model.differences(from: reference.screen, limit: 1)
                    let cursor = HybridParityFixture.Cursor(x: model.x, y: model.y, visible: model.cursorVisible)
                    if !differences.isEmpty || cursor != reference.cursor {
                        outcome.wrong = "frame \(frame): \(differences.first ?? "cursor \(cursor) against \(reference.cursor)")"
                    }
                default:
                    break
                }
            }
        }
        return outcome
    }

    private func randomBytes(_ count: Int, _ rng: inout SeededGenerator) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    /// Random frame streams: a stretch of a recorded attach (lean or v1), with 1 to 3 of the
    /// mutations above. The decoder never crashes and never draws after it fell back; a stream
    /// with only mutations the wire can tell either draws exactly the reference at every frame or
    /// falls back (a full resync, then bytes mode) before it draws a wrong one. Seeded:
    /// the same 6,000 cases on every run.
    @Test func randomFrameStreamsNeverDrawAWrongScreenSilently() throws {
        #expect(!Thread.isMainThread, "6,000 fuzz cases hold the main thread")
        let fixtures = HybridParityFixture.all
        try #require(fixtures.count == HybridParityFixture.names.count, "the parity fixtures")
        var rng = SeededGenerator(seed: 0x4405_2C0F_FEE0_7CEE)
        var tally: [String: [String: Int]] = [:]
        var failures: [String] = []
        let cases = 6000
        for index in 0..<cases {
            let fixture = fixtures[index % fixtures.count]
            let lean = index % 2 == 0
            let connections = (fixture.steps.map(\.connection).max() ?? 0) + 1
            let connection = Int.random(in: 0..<connections, using: &rng)
            let segment = Array(fixture.steps.filter { $0.connection == connection }.prefix(40))
            guard segment.count >= 3 else { continue }
            let resume = segment[0].base.map { (stream: fixture.stream, frame: $0) }
            var lines = segment.map { lean ? HybridWire.leanLine($0.lean) : HybridWire.v1Line($0, stream: fixture.stream) }
            var applied: [Mutation] = []
            // The recorded step each line carries (nil: an inserted line) and whether it is one the
            // phone must refuse, kept in step with `lines` through every mutation: a later drop may
            // take a bad line out again.
            var origin: [Int?] = segment.indices.map { Optional($0) }
            var bad = [Bool](repeating: false, count: lines.count)
            func insert(_ line: Data, at index: Int, bad isBad: Bool, origin from: Int? = nil) {
                lines.insert(line, at: index)
                bad.insert(isBad, at: index)
                origin.insert(from, at: index)
            }
            func replace(_ index: Int, _ line: Data, bad isBad: Bool) {
                lines[index] = line
                bad[index] = isBad
            }
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                var kind = Mutation.allCases.randomElement(using: &rng) ?? .truncate
                if !lean, kind == .garbageFrame { kind = .flipByte }
                let at = Int.random(in: 1..<lines.count, using: &rng)
                let step = segment[origin[at] ?? origin[...at].compactMap { $0 }.last ?? 0]
                let rows = step.rows
                let columns = step.columns
                switch kind {
                case .truncate:
                    if lean {
                        let length = Int.random(in: 0..<max(1, step.lean.count), using: &rng)
                        replace(at, HybridWire.leanLine(step.lean.prefix(length)), bad: true)
                    } else {
                        let length = Int.random(in: 0..<max(1, step.delta.count), using: &rng)
                        replace(at, HybridWire.v1Line(step, stream: fixture.stream, delta: step.delta.prefix(length)), bad: true)
                    }
                case .extremeVarint:
                    if lean {
                        let frames = HybridWire.extremeLeanFrames(stream: fixture.stream, columns: columns, rows: rows)
                        replace(at, HybridWire.leanLine(frames[Int.random(in: 0..<frames.count, using: &rng)].frame), bad: true)
                    } else {
                        let deltas = HybridWire.extremeDeltas
                        replace(at, HybridWire.v1Line(step, stream: fixture.stream,
                                                      delta: deltas[Int.random(in: 0..<deltas.count, using: &rng)].delta), bad: true)
                    }
                case .garbageLine:
                    insert(randomBytes(Int.random(in: 1...60, using: &rng), &rng) + Data([0x0A]), at: at, bad: true)
                case .spanOutOfGrid, .clearOutOfGrid, .cursorOutOfGrid, .shiftPastGrid, .controlInCell:
                    let cell = AgentCLIHybridFrame.Cell(text: "x", style: .plain)
                    let edge = Int.random(in: 0...2, using: &rng)
                    if lean {
                        let frame: Data = switch kind {
                        case .spanOutOfGrid:
                            // Only a keyframe brings its own style: it opens the attach.
                            HybridWire.leanKeyframe(stream: fixture.stream, columns: columns, rows: rows, frame: segment[0].frame,
                                                    row: edge == 0 ? rows + edge : 0, column: edge == 0 ? 0 : columns - 1,
                                                    cells: [cell, cell, cell])
                        case .clearOutOfGrid:
                            HybridWire.leanFollowing(clears: [edge == 0 ? (rows + 1, 0, 3) : (0, columns - 2, 3 + edge)])
                        case .cursorOutOfGrid:
                            HybridWire.leanFollowing(cursor: edge == 0 ? (columns + edge, 0) : (0, rows + edge))
                        case .shiftPastGrid:
                            HybridWire.leanFollowing(shift: (edge == 0 ? -1 : 1) * (rows + 1 + edge))
                        default:
                            HybridWire.leanKeyframe(stream: fixture.stream, columns: columns, rows: rows, frame: segment[0].frame,
                                                    row: 0, column: 0, cells: [.init(text: ["\u{1b}[2J", "\r", "a\u{08}"][edge], style: .plain)])
                        }
                        if kind == .spanOutOfGrid || kind == .controlInCell {
                            replace(0, HybridWire.leanLine(frame), bad: true)
                        } else {
                            insert(HybridWire.leanLine(frame), at: at, bad: true)
                        }
                    } else {
                        let delta: Data
                        var cursor: (Int, Int)?
                        switch kind {
                        case .spanOutOfGrid:
                            delta = HybridWire.delta(shift: 0, spans: [.set(row: edge == 0 ? rows : 0, column: edge == 0 ? 0 : columns - 1,
                                                                            cells: [cell, cell])])
                        case .clearOutOfGrid:
                            delta = HybridWire.delta(shift: 0, spans: [.clear(row: edge == 0 ? rows + 1 : 0, column: columns - 1, count: 2 + edge)])
                        case .cursorOutOfGrid:
                            delta = step.delta
                            cursor = edge == 0 ? (columns, 0) : (0, rows + edge)
                        case .shiftPastGrid:
                            delta = HybridWire.delta(shift: rows + 1 + edge, spans: [])
                        default:
                            delta = HybridWire.delta(shift: 0, spans: [.set(row: 0, column: 0,
                                                                            cells: [.init(text: ["\u{1b}[2J", "\r", "a\u{08}"][edge], style: .plain)])])
                        }
                        replace(at, HybridWire.v1Line(step, stream: fixture.stream, delta: delta, cursor: cursor), bad: true)
                    }
                case .duplicate:
                    insert(lines[at], at: at, bad: bad[at], origin: origin[at])
                case .reorder:
                    if at + 1 < lines.count {
                        lines.swapAt(at, at + 1)
                        bad.swapAt(at, at + 1)
                        origin.swapAt(at, at + 1)
                    }
                case .drop:
                    lines.remove(at: at)
                    bad.remove(at: at)
                    origin.remove(at: at)
                    if lines.count < 2 { insert(HybridWire.leanLine(Data()), at: lines.count, bad: false) }
                case .wrongBase:
                    if lean {
                        kind = .garbageFrame
                        insert(HybridWire.leanLine(randomBytes(Int.random(in: 1...24, using: &rng), &rng)), at: at, bad: false)
                    } else {
                        replace(at, HybridWire.v1Line(step, stream: fixture.stream, base: .some((step.base ?? 0) + 100_000)), bad: true)
                    }
                case .otherStream:
                    if lean {
                        kind = .flipByte
                        var bytes = step.lean
                        let position = Int.random(in: 0..<max(1, bytes.count), using: &rng)
                        if position < bytes.count { bytes[position] ^= UInt8(1 << Int.random(in: 0...7, using: &rng)) }
                        replace(at, HybridWire.leanLine(bytes), bad: false)
                    } else {
                        // A frame on another stream cannot apply; a keyframe of one is a whole
                        // screen (a resize starts a new stream), which the frame after it refuses.
                        replace(at, HybridWire.v1Line(step, stream: "another-stream"), bad: step.base != nil)
                    }
                case .flipByte:
                    var bytes = lean ? step.lean : step.delta
                    let position = Int.random(in: 0..<max(1, bytes.count), using: &rng)
                    if position < bytes.count { bytes[position] ^= UInt8(1 << Int.random(in: 0...7, using: &rng)) }
                    replace(at, lean ? HybridWire.leanLine(bytes) : HybridWire.v1Line(step, stream: fixture.stream, delta: bytes), bad: false)
                case .garbageFrame:
                    insert(HybridWire.leanLine(randomBytes(Int.random(in: 1...24, using: &rng), &rng)), at: at, bad: false)
                }
                applied.append(kind)
            }
            let tellable: Bool = applied.allSatisfy { kind in
                switch kind {
                case .flipByte, .garbageFrame: false
                case .duplicate, .reorder, .drop: !lean
                default: true
                }
            }
            let outcome = run(lines, fixture: fixture, connection: connection, resume: resume)
            let form = lean ? "lean" : "v1"
            let group = tellable ? "\(form) told" : "\(form) not told"
            let result = outcome.wrong != nil ? "wrong" : outcome.fellBack ? "fellBack" : "matched"
            tally[group, default: [:]][result, default: 0] += 1
            tally[group, default: [:]]["cases", default: 0] += 1
            for kind in applied { tally["mutations", default: [:]][kind.rawValue, default: 0] += 1 }
            let caseName = "case \(index) \(fixture.name) \(form) \(applied.map(\.rawValue))"
            if outcome.drewAfterFallback { failures.append("\(caseName): drew after a fallback") }
            if tellable, let wrong = outcome.wrong { failures.append("\(caseName): \(wrong)") }
            if tellable, bad.contains(true), !outcome.fellBack { failures.append("\(caseName): no fallback") }
        }
        #expect(failures.isEmpty, "\(failures.count) cases: \(failures.prefix(5))")
        let summary = (try? JSONSerialization.data(withJSONObject: tally, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        print("HYBRID_PROOF fuzz {\"cases\":\(cases),\"seed\":\"0x44052C0FFEE07CEE\",\"failures\":\(failures.count),\"tally\":\(summary)}")
    }

    // MARK: The fallback signal

    private let keyframeData = Data([0, 0, 0, 2, 0, 2, 5, 1, 174, 0, 1, 0x68, 0x69, 1, 0, 6])

    private func v1Event(frame: Int, base: Int?, data: Data? = nil, stream: String = "s1") -> [String: Any] {
        var object: [String: Any] = [
            "event": "agent-cli-frame", "surface": 7, "stream": stream, "frame": frame,
            "cols": 20, "rows": 4, "data": (data ?? keyframeData).base64EncodedString(),
            "cursor_x": 1, "cursor_y": 3, "cursor_visible": true,
        ]
        if let base { object["base"] = base }
        return object
    }

    /// Review F1 on #44052: a count, place, length or style at the edge of `UInt64` or `Int`
    /// trapped (`Int(UInt64.max)`, `abs(Int.min)`, an offset plus a length past `Int.max`) before
    /// the frame could fall back. Every such frame, v1 or lean, must fall back and draw nothing.
    @Test func extremeVarintsFallBackInsteadOfCrashing() {
        for (name, delta) in HybridWire.extremeDeltas {
            var parser = DaemonTerminalEventParser(surface: 7)
            let events = parser.parse(FakeTerminalDaemon.line(v1Event(frame: 1, base: nil, data: delta)))
            #expect(events.contains { if case .hybridFallback = $0 { true } else { false } }, "v1 \(name): \(events)")
            #expect(!events.contains { if case .hybridFrame = $0 { true } else { false } }, "v1 \(name) drew")
        }
        for (name, frame) in HybridWire.extremeLeanFrames(stream: "s1", columns: 20, rows: 4) {
            var parser = DaemonTerminalEventParser(surface: 1)
            let events = parser.parse(HybridWire.leanLine(frame))
            #expect(events.contains { if case .hybridFallback = $0 { true } else { false } }, "lean \(name): \(events)")
            #expect(!events.contains { if case .hybridFrame = $0 { true } else { false } }, "lean \(name) drew")
        }
        // A keyframe numbered Int.max, then a frame that follows it: its number would be Int.max + 1.
        var parser = DaemonTerminalEventParser(surface: 1)
        let last = HybridWire.leanKeyframe(stream: "s1", columns: 20, rows: 4, frame: Int.max, row: 0, column: 0,
                                           cells: [.init(text: "x", style: .plain)])
        #expect(parser.parse(HybridWire.leanLine(last)).contains { if case .hybridFrame = $0 { true } else { false } })
        let next = parser.parse(HybridWire.leanLine(HybridWire.leanFollowing()))
        #expect(next.contains { if case .hybridFallback = $0 { true } else { false } }, "after frame Int.max: \(next)")
    }

    @Test func aFrameThatDoesNotApplyFallsBackAndDrawsNothingAfter() {
        var parser = DaemonTerminalEventParser(surface: 7)
        #expect(!parser.parse(FakeTerminalDaemon.line(v1Event(frame: 1, base: nil))).isEmpty)
        let gap = parser.parse(FakeTerminalDaemon.line(v1Event(frame: 3, base: 2, data: Data([0, 0, 0, 0]))))
        #expect(gap == [.hybridFallback(reason: "frame 3 applies on 2, the mirror shows 1")])
        // Nothing after it draws, a good frame included.
        #expect(parser.parse(FakeTerminalDaemon.line(v1Event(frame: 2, base: 1, data: Data([0, 0, 0, 0])))).isEmpty)
        #expect(parser.parse(Data("not json\n".utf8)).isEmpty)
    }

    @Test func aResumeMustApplyOnTheFrameItNamed() {
        var parser = DaemonTerminalEventParser(surface: 7, hybridResume: (stream: "s1", frame: 5))
        let other = parser.parse(FakeTerminalDaemon.line(v1Event(frame: 9, base: 5, data: Data([0, 0, 0, 0]), stream: "s2")))
        #expect(other.count == 1 && { if case .hybridFallback = other[0] { true } else { false } }())
        var fresh = DaemonTerminalEventParser(surface: 7)
        let orphan = fresh.parse(FakeTerminalDaemon.line(v1Event(frame: 9, base: 5, data: Data([0, 0, 0, 0]))))
        #expect(orphan.count == 1 && { if case .hybridFallback = orphan[0] { true } else { false } }(), "a delta on a screen it never drew")
    }

    @Test func outOfGridAndControlCellsAreRefused() throws {
        let plain = AgentCLIHybridFrame.Style.plain
        func frame(_ spans: [AgentCLIHybridFrame.Span], shift: Int = 0, cursor: (Int, Int) = (0, 0)) -> AgentCLIHybridFrame {
            AgentCLIHybridFrame(stream: "s", frame: 1, base: nil, columns: 20, rows: 4, delta: .init(shift: shift, spans: spans),
                                cursorX: cursor.0, cursorY: cursor.1, cursorVisible: true)
        }
        let x = AgentCLIHybridFrame.Cell(text: "x", style: plain)
        #expect(frame([.set(row: 3, column: 18, cells: [x, x])]).invalidReason == nil)
        #expect(frame([.set(row: 4, column: 0, cells: [x])]).invalidReason != nil)
        #expect(frame([.set(row: 0, column: 19, cells: [x, x])]).invalidReason != nil)
        #expect(frame([.clear(row: 0, column: 15, count: 6)]).invalidReason != nil)
        #expect(frame([], cursor: (20, 0)).invalidReason != nil)
        #expect(frame([], shift: 5).invalidReason != nil)
        #expect(frame([], shift: -4).invalidReason == nil)
        for text in ["\u{1b}[2J", "\r", "a\u{07}", "\u{9b}2J", "\u{7f}"] {
            #expect(frame([.set(row: 0, column: 0, cells: [.init(text: text, style: plain)])]).invalidReason != nil, "\(text.debugDescription)")
        }
        #expect(frame([.set(row: 0, column: 0, cells: [.init(text: "界", style: plain), .init(text: "", style: plain)])]).invalidReason == nil)
    }

    @MainActor private func waitUntil(attempts: Int = 500, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @MainActor private func defaults(hybrid: Bool) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "AgentCLIHybridProofTests-\(UUID().uuidString)"))
        defaults.set(hybrid, forKey: DaemonTerminalSession.agentCLIHybridDefaultsKey)
        return defaults
    }

    private func capabilities(_ daemon: FakeTerminalDaemon) -> [[String]] {
        daemon.recorded.filter { $0["cmd"] as? String == "set-client-info" }.map { $0["capabilities"] as? [String] ?? [] }
    }

    private func attaches(_ daemon: FakeTerminalDaemon) -> [[String: Any]] {
        daemon.recorded.filter { $0["cmd"] as? String == "attach-surface" }
    }

    /// A frame the phone cannot draw makes the session attach again at once for a full resync
    /// (no resume: the Mac sends a keyframe); a second one, in bytes mode (no hybrid
    /// capability declared: the PTY's bytes, as before the hybrid stream).
    @MainActor @Test func aFrameThatCannotBeDrawnResyncsThenFallsBackToBytes() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.hybridEvents = [v1Event(frame: 1, base: nil), v1Event(frame: 2, base: 9, data: Data([0, 0, 0, 0]))]
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        session.agentCLIHybridDefaults = try defaults(hybrid: true)
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { attaches(daemon).count == 3 && session.isAttached }
        let declared = capabilities(daemon)
        #expect(declared.count == 3)
        #expect(declared.prefix(2).allSatisfy { $0.contains("agent-cli-hybrid-v1") && $0.contains("agent-cli-hybrid-v2") }, "\(declared)")
        #expect(declared.last == DaemonTerminalSession.clientCapabilities, "bytes mode: \(declared)")
        #expect(attaches(daemon).allSatisfy { $0["hybrid_stream"] == nil && $0["hybrid_frame"] == nil }, "never a resume from a bad screen")
        #expect(session.hybridFallbacks == 2)
        session.stop()
    }

    // MARK: 4. Old viewers and old daemons

    /// Review F2 on #44052: a reattach named the stream and frame to resume even when the
    /// daemon's `identify` did not list `agent-cli-hybrid-v1`, and such a daemon refuses those
    /// fields. The phone resumes only on a daemon that lists the capability, otherwise it
    /// attaches for bytes as before.
    @MainActor @Test func aResumeGoesOnlyToADaemonThatListsTheHybridStream() async throws {
        for daemonStillLists in [true, false] {
            let daemon = FakeTerminalDaemon()
            daemon.advertisesHybrid = true
            daemon.hybridEvents = [v1Event(frame: 1, base: nil)]
            let link = MockMacLink { service, line in daemon.respond(service, line) }
            let channels = ChannelLog()
            let session = DaemonTerminalSession(surface: 7) {
                let channel = try await link.openChannel(service: "daemon", args: [:])
                channels.append(channel)
                return DaemonClient(channel: channel)
            }
            session.agentCLIHybridDefaults = try defaults(hybrid: true)
            var events: [TerminalSessionEvent] = []
            session.start { events.append($0) }
            func output() -> String {
                events.compactMap { event -> String? in
                    if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
                    return nil
                }.joined()
            }
            // The frame drew: the phone now has a stream and frame to resume from.
            // The frame's last bytes: the cursor's place (1, 3), then shown.
            try await waitUntil { session.isAttached && output().contains("\u{1b}[4;2H\u{1b}[?25h") }
            if !daemonStillLists {
                // The Mac's daemon was replaced by one from before the hybrid stream.
                daemon.advertisesHybrid = false
                daemon.hybridEvents = []
            }
            await channels.last?.close(code: "link_closed", reason: "link dropped")
            try await waitUntil { !session.isAttached }
            session.reconnect()
            try await waitUntil { attaches(daemon).count == 2 && session.isAttached }
            let second = attaches(daemon)[1]
            if daemonStillLists {
                #expect(second["hybrid_stream"] as? String == "s1" && second["hybrid_frame"] as? Int == 1, "\(second)")
            } else {
                #expect(second["hybrid_stream"] == nil && second["hybrid_frame"] == nil, "resumed on an old daemon: \(second)")
            }
            session.stop()
        }
    }

    /// The screen's output and the commands of one attach, a link drop and a reattach.
    @MainActor private func attachTwice(hybridSetting: Bool, daemonKnowsHybrid: Bool) async throws -> (output: String, daemon: FakeTerminalDaemon) {
        let daemon = FakeTerminalDaemon()
        if daemonKnowsHybrid {
            // A new daemon: it would send frames to a phone that declared the capability.
            daemon.hybridEvents = [v1Event(frame: 1, base: nil)]
        }
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        session.agentCLIHybridDefaults = try defaults(hybrid: hybridSetting)
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { events.contains(.alternateScreen(true)) }
        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { !session.isAttached }
        session.reconnect()
        func output() -> String {
            events.compactMap { event -> String? in
                if case .output(let data) = event { return String(decoding: data, as: UTF8.self) }
                return nil
            }.joined()
        }
        try await waitUntil { attaches(daemon).count == 2 && session.isAttached && output().components(separatedBy: "TUI").count == 3 }
        let text = output()
        session.stop()
        return (text, daemon)
    }

    /// An old phone (the setting off: it declares neither hybrid capability) on a new daemon
    /// sends exactly what a phone sent before the hybrid stream and gets the PTY's bytes; a new
    /// phone (the setting on) on an old daemon (it never sends a frame) gets the same bytes and
    /// never asks to resume a stream. The daemon's side of both is cmux-tui's
    /// `old_viewers_get_what_they_got_before` and the SDK's `a_new_viewer_on_an_old_daemon_falls_back_to_bytes`.
    @MainActor @Test func oldPhonesAndOldDaemonsKeepTheByteStream() async throws {
        let oldPhone = try await attachTwice(hybridSetting: false, daemonKnowsHybrid: true)
        let newPhone = try await attachTwice(hybridSetting: true, daemonKnowsHybrid: false)
        #expect(capabilities(oldPhone.daemon) == [DaemonTerminalSession.clientCapabilities, DaemonTerminalSession.clientCapabilities])
        #expect(capabilities(newPhone.daemon).allSatisfy { $0.contains("agent-cli-hybrid-v2") })
        #expect(oldPhone.output == newPhone.output && oldPhone.output.contains("hello\r\n$ "), "\(oldPhone.output.debugDescription) | \(newPhone.output.debugDescription)")
        for daemon in [oldPhone.daemon, newPhone.daemon] {
            #expect(attaches(daemon).allSatisfy { $0["hybrid_stream"] == nil && $0["hybrid_frame"] == nil })
        }
        print("HYBRID_PROOF old-viewers {\"oldPhoneNewDaemon\":\"bytes\",\"newPhoneOldDaemon\":\"bytes\"}")
    }
    /// The screen model erases a wide glyph whole, as Ghostty does, when an erase (ECH) covers
    /// only one of its halves. shell-bash-5.2 frame 6 (since #51214) erases each wide glyph with
    /// ECH 1 at its lead; a model that kept the width-0 trailing half drew a screen Ghostty never does.
    @Test func anEraseOverHalfAWideGlyphErasesTheGlyph() {
        func row(after bytes: String) -> [HybridParityFixture.Cell] {
            var model = HybridScreenModel(columns: 6, rows: 1, widths: ["日": 2])
            model.write(Data(bytes.utf8))
            return model.cells[0]
        }
        func blank(_ cell: HybridParityFixture.Cell) -> Bool { cell.width == 1 && cell.text.isEmpty }
        // ECH 1 at the lead: the trailing half goes too.
        let atLead = row(after: "\u{1b}[1;1H日x\u{1b}[1;1H\u{1b}[1X")
        #expect(blank(atLead[0]) && blank(atLead[1]), "\(atLead)")
        #expect(atLead[2].text == "x")
        // ECH 1 at the trailing half: the lead goes too.
        let atTail = row(after: "\u{1b}[1;1H日x\u{1b}[1;2H\u{1b}[1X")
        #expect(blank(atTail[0]) && blank(atTail[1]), "\(atTail)")
        #expect(atTail[2].text == "x")
        // A run that ends on a lead: its trailing half past the run goes too.
        let endsOnLead = row(after: "\u{1b}[1;1Ha日x\u{1b}[1;1H\u{1b}[2X")
        #expect(endsOnLead.prefix(3).allSatisfy(blank), "\(endsOnLead)")
        #expect(endsOnLead[3].text == "x")
        // No cell anywhere is a trailing half without its lead.
        for cells in [atLead, atTail, endsOnLead] {
            for (column, cell) in cells.enumerated() where cell.width == 0 {
                #expect(column > 0 && cells[column - 1].width == 2, "\(cells)")
            }
        }
    }
}
