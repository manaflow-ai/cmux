import Foundation
@testable import CmuxMobileLive

/// One recorded session's parity fixture (`verify/agent-cli-hybrid/parity/NAME.json`), made by
/// cmux-tui's `the_phones_parity_fixtures_hold_and_are_current` (cmux-agent-cli-render
/// `tests/parity.rs`), which also checks that it is current.
///
/// The reference is ghostty-vt fed the session's PTY bytes: the terminal the daemon reads every
/// frame from and the engine the phone draws with. The Rust encoder is what is under test, so it
/// is not the reference. Each step is one frame as the phone gets it (a 4 s drop and a resume on
/// a new connection included): its lean bytes, its v1 delta, the terminal bytes cmux-tui's
/// `vt::frame_bytes` makes of it (which that test draws into a second ghostty-vt and checks
/// against the reference cell for cell), and the reference screen with its cursor.
struct HybridParityFixture: Sendable {
    struct Cell: Equatable, Sendable {
        var text: String
        /// 1 narrow, 2 the lead of a wide glyph, 0 its trailing half.
        var width: Int
        var style: AgentCLIHybridFrame.Style
    }

    struct Step: Sendable {
        /// The phone's connection: 0 until the drop, then 1.
        var connection: Int
        var frame: Int
        var base: Int?
        var atMs: Int
        var columns: Int
        var rows: Int
        var lean: Data
        var delta: Data
        var terminalBytes: Data
        var cursor: Cursor
        var screen: [[Cell]]
    }

    struct Cursor: Equatable, Sendable {
        var x: Int
        var y: Int
        var visible: Bool
    }

    let name: String
    let stream: String
    /// The width ghostty-vt gave each non-ASCII glyph of the session.
    let widths: [String: Int]
    let steps: [Step]

    static let names = ["claude-code-2.1.310", "codex-0.164.0", "opencode-1.19.5", "shell-bash-5.2"]

    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("verify/agent-cli-hybrid/parity/\(name).json")
    }

    static let all: [HybridParityFixture] = names.compactMap { load($0) }

    static func load(_ name: String) -> HybridParityFixture? {
        guard let data = try? Data(contentsOf: url(name)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = root["stream"] as? String,
              let styleList = root["styles"] as? [[Any]], let rowList = root["grid_rows"] as? [[Any]],
              let stepList = root["steps"] as? [[String: Any]] else { return nil }
        func color(_ value: Any) -> AgentCLIHybridFrame.Color {
            if let index = value as? Int { return .palette(UInt8(clamping: index)) }
            if let rgb = value as? [Int], rgb.count == 3 {
                return .rgb(UInt8(clamping: rgb[0]), UInt8(clamping: rgb[1]), UInt8(clamping: rgb[2]))
            }
            return .standard
        }
        let styles = styleList.map { entry in
            AgentCLIHybridFrame.Style(fg: color(entry[0]), bg: color(entry[1]), attrs: entry[2] as? Int ?? 0)
        }
        let rows: [[Cell]] = rowList.map { runs in
            var cells: [Cell] = []
            for case let run as [Any] in runs {
                let style = styles[run[0] as? Int ?? 0]
                if let plain = run[1] as? String {
                    cells += plain.map { Cell(text: String($0), width: 1, style: style) }
                } else if let list = run[1] as? [Any] {
                    for item in list {
                        if let text = item as? String {
                            cells.append(Cell(text: text, width: 1, style: style))
                        } else {
                            // The trailing half of the wide glyph before it.
                            if !cells.isEmpty { cells[cells.count - 1].width = 2 }
                            cells.append(Cell(text: "", width: 0, style: style))
                        }
                    }
                }
            }
            return cells
        }
        let steps: [Step] = stepList.compactMap { step in
            guard let connection = step["c"] as? Int, let frame = step["f"] as? Int,
                  let columns = step["cols"] as? Int, let rowCount = step["rows"] as? Int,
                  let lean = (step["lean"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let delta = (step["d"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let bytes = (step["vt"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let cursor = step["cursor"] as? [Any], cursor.count == 3,
                  let screen = step["screen"] as? [Int] else { return nil }
            return Step(connection: connection, frame: frame, base: step["b"] as? Int, atMs: step["at"] as? Int ?? 0,
                        columns: columns, rows: rowCount, lean: lean, delta: delta, terminalBytes: bytes,
                        cursor: Cursor(x: cursor[0] as? Int ?? -1, y: cursor[1] as? Int ?? -1, visible: cursor[2] as? Bool ?? false),
                        screen: screen.map { rows[$0] })
        }
        guard steps.count == stepList.count else { return nil }
        return HybridParityFixture(name: name, stream: stream, widths: root["widths"] as? [String: Int] ?? [:], steps: steps)
    }

    /// The reference screen at `frame` of `connection` (nil: no such frame).
    func screen(connection: Int, frame: Int) -> Step? {
        steps.last { $0.connection == connection && $0.frame == frame }
    }

    /// The reference screen at `frame`, any connection (a resume's base is the last frame of the
    /// connection before).
    func screen(frame: Int) -> Step? { steps.last { $0.frame == frame } }
}

/// The phone's terminal as far as the decoder's bytes reach it: the sequences
/// ``AgentCLIHybridFrame/terminalBytes`` writes (CUP, ED 2, ECH, SD, SGR, line feeds on the last
/// row, DECTCEM), each glyph laid out as the phone's Ghostty lays it out (the fixture's widths,
/// measured by ghostty-vt; a wide glyph on the last column wraps), and anything else a terminal
/// would do with control bytes in a cell (CR, BS, an ESC that starts a sequence), so a frame that
/// smuggles one shows on the grid.
struct HybridScreenModel {
    var columns: Int
    var rows: Int
    var cells: [[HybridParityFixture.Cell]]
    var x = 0
    var y = 0
    var cursorVisible = true
    private var pendingWrap = false
    private var style = AgentCLIHybridFrame.Style.plain
    let widths: [String: Int]
    /// Rows the line feeds moved off the top.
    private(set) var scrollback: [[HybridParityFixture.Cell]] = []

    init(columns: Int, rows: Int, widths: [String: Int]) {
        self.columns = columns
        self.rows = rows
        self.widths = widths
        cells = Array(repeating: Array(repeating: Self.blank(.plain), count: columns), count: rows)
    }

    /// A model showing the reference screen of `step` (a resume's base).
    init(step: HybridParityFixture.Step, widths: [String: Int]) {
        self.init(columns: step.columns, rows: step.rows, widths: widths)
        cells = step.screen
        x = step.cursor.x
        y = step.cursor.y
        cursorVisible = step.cursor.visible
    }

    static func blank(_ style: AgentCLIHybridFrame.Style) -> HybridParityFixture.Cell {
        .init(text: "", width: 1, style: .init(fg: .standard, bg: style.bg, attrs: 0))
    }

    /// Columns `text` takes when the session never measured it: cmux-tui's `char_width`.
    static func fallbackWidth(_ text: String) -> Int {
        let width = text.unicodeScalars.reduce(0) { total, scalar in
            switch scalar.value {
            case 0x0300...0x036F, 0x200B...0x200F, 0xFE00...0xFE0F: total
            case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
                 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
                 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F,
                 0x1F900...0x1F9FF, 0x20000...0x3FFFD: total + 2
            default: total + 1
            }
        }
        return min(max(width, 1), 2)
    }

    mutating func write(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        var state = 0  // 0 text, 1 after ESC, 2 in CSI
        var params = ""
        for character in text {
            let scalars = character.unicodeScalars
            let first = scalars.first?.value ?? 0
            switch state {
            case 1:
                state = character == "[" ? 2 : 0
                params = ""
                continue
            case 2:
                if scalars.count == 1, (0x30...0x3F).contains(first) {
                    params.append(character)
                } else if scalars.count == 1, (0x20...0x2F).contains(first) {
                    continue
                } else if scalars.count == 1, (0x40...0x7E).contains(first) {
                    csi(character, params)
                    state = 0
                } else {
                    state = 0
                }
                continue
            default:
                break
            }
            if character == "\u{1b}" {
                state = 1
            } else if character == "\n" {
                lineFeed()
            } else if character == "\r" {
                x = 0
                pendingWrap = false
            } else if character == "\u{08}" {
                x = max(0, x - 1)
                pendingWrap = false
            } else if character == "\r\n" {
                x = 0
                lineFeed()
            } else if scalars.count == 1, first < 0x20 || (0x7F...0x9F).contains(first) {
                continue
            } else {
                put(String(character))
            }
        }
    }

    private mutating func csi(_ final: Character, _ params: String) {
        let isPrivate = params.hasPrefix("?")
        let numbers = params.drop(while: { $0 == "?" }).split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        func number(_ index: Int, _ fallback: Int) -> Int {
            index < numbers.count ? (numbers[index] ?? fallback) : fallback
        }
        switch final {
        case "H", "f":
            y = min(max(number(0, 1), 1), rows) - 1
            x = min(max(number(1, 1), 1), columns) - 1
            pendingWrap = false
        case "J" where number(0, 0) == 2:
            cells = Array(repeating: Array(repeating: Self.blank(style), count: columns), count: rows)
        case "X":
            let count = max(number(0, 1), 1)
            for column in x..<min(columns, x + count) {
                cells[y][column] = Self.blank(style)
            }
        case "T":
            let count = min(max(number(0, 1), 1), rows)
            cells.removeLast(count)
            cells.insert(contentsOf: Array(repeating: Array(repeating: Self.blank(style), count: columns), count: count), at: 0)
        case "m":
            sgr(numbers.map { $0 ?? 0 })
        case "h" where isPrivate, "l" where isPrivate:
            if numbers.contains(25) { cursorVisible = final == "h" }
        default:
            break
        }
    }

    private mutating func sgr(_ codes: [Int]) {
        var index = 0
        let codes = codes.isEmpty ? [0] : codes
        while index < codes.count {
            let code = codes[index]
            func extended() -> AgentCLIHybridFrame.Color? {
                if index + 2 < codes.count, codes[index + 1] == 5 {
                    defer { index += 2 }
                    return .palette(UInt8(clamping: codes[index + 2]))
                }
                if index + 4 < codes.count, codes[index + 1] == 2 {
                    defer { index += 4 }
                    return .rgb(UInt8(clamping: codes[index + 2]), UInt8(clamping: codes[index + 3]), UInt8(clamping: codes[index + 4]))
                }
                return nil
            }
            switch code {
            case 0: style = .plain
            case 1: style.attrs |= 0x0001
            case 2: style.attrs |= 0x0010
            case 3: style.attrs |= 0x0002
            case 4: style.attrs |= 0x0100
            case 5: style.attrs |= 0x0040
            case 7: style.attrs |= 0x0008
            case 8: style.attrs |= 0x0020
            case 9: style.attrs |= 0x0004
            case 30...37: style.fg = .palette(UInt8(code - 30))
            case 90...97: style.fg = .palette(UInt8(code - 90 + 8))
            case 40...47: style.bg = .palette(UInt8(code - 40))
            case 100...107: style.bg = .palette(UInt8(code - 100 + 8))
            case 39: style.fg = .standard
            case 49: style.bg = .standard
            case 38: if let color = extended() { style.fg = color }
            case 48: if let color = extended() { style.bg = color }
            default: break
            }
            index += 1
        }
    }

    private mutating func lineFeed() {
        pendingWrap = false
        if y == rows - 1 {
            scrollback.append(cells.removeFirst())
            cells.append(Array(repeating: Self.blank(style), count: columns))
        } else {
            y += 1
        }
    }

    /// Overwriting half of a wide glyph blanks its other half.
    private mutating func unwide(_ column: Int) {
        guard (0..<columns).contains(column) else { return }
        if cells[y][column].width == 2, column + 1 < columns {
            cells[y][column + 1] = .init(text: "", width: 1, style: cells[y][column + 1].style)
        } else if cells[y][column].width == 0, column > 0 {
            cells[y][column - 1] = .init(text: "", width: 1, style: cells[y][column - 1].style)
        }
    }

    private mutating func put(_ text: String) {
        let ascii = text.utf8.count == 1
        let width = ascii ? 1 : widths[text] ?? Self.fallbackWidth(text)
        if pendingWrap {
            x = 0
            lineFeed()
        }
        if width == 2, x == columns - 1 {
            cells[y][x] = Self.blank(style)
            x = 0
            lineFeed()
        }
        unwide(x)
        if width == 2 { unwide(x + 1) }
        cells[y][x] = .init(text: text, width: width, style: style)
        if width == 2 { cells[y][x + 1] = .init(text: "", width: 0, style: style) }
        x += width
        if x >= columns {
            x = columns - 1
            pendingWrap = true
        }
    }

    /// The cells that differ from `reference` ("row,column phone|reference"), the first
    /// `limit`. Two cells match when they draw the same pixels (cmux-tui's `Cell::looks_same`):
    /// the same glyph or both blank, the same width, background and attributes, and the same
    /// foreground unless neither draws a glyph (inverse always shows it).
    func differences(from reference: [[HybridParityFixture.Cell]], limit: Int = 4) -> [String] {
        var out: [String] = []
        guard reference.count == rows, reference.allSatisfy({ $0.count == columns }) else {
            return ["grid \(columns)x\(rows) against \(reference.first?.count ?? 0)x\(reference.count)"]
        }
        func isBlank(_ cell: HybridParityFixture.Cell) -> Bool {
            cell.width != 0 && (cell.text.isEmpty || cell.text == " " || cell.text == "\u{A0}")
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let mine = cells[row][column]
                let theirs = reference[row][column]
                let blank = isBlank(mine) && isBlank(theirs)
                let fgShows = !blank || (mine.style.attrs | theirs.style.attrs) & 0x0008 != 0
                let same = (blank || mine.text == theirs.text) && mine.width == theirs.width
                    && mine.style.bg == theirs.style.bg && mine.style.attrs == theirs.style.attrs
                    && (!fgShows || mine.style.fg == theirs.style.fg)
                if !same {
                    out.append("\(row),\(column) \(mine)|\(theirs)")
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }
}

/// A seeded generator (SplitMix64): the same cases on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `agent-cli-hybrid-v1` deltas and lean frames written by hand (cmux-tui's
/// `hybrid::Delta::encode` and `lean::LeanEncoder`), for frames the daemon never sends.
enum HybridWire {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    static func zigzag(_ value: Int) -> UInt64 { UInt64(bitPattern: Int64((value << 1) ^ (value >> 63))) }

    static func color(_ color: AgentCLIHybridFrame.Color) -> [UInt8] {
        switch color {
        case .standard: [0]
        case .palette(let index): [1, index]
        case let .rgb(red, green, blue): [2, red, green, blue]
        }
    }

    /// A v1 delta (`Delta::encode`): seq 0, at 0.
    static func delta(shift: Int, spans: [AgentCLIHybridFrame.Span]) -> Data {
        var out = varint(0) + varint(0) + varint(zigzag(shift)) + varint(UInt64(spans.count))
        for span in spans {
            switch span {
            case let .set(row, column, cells):
                out += varint(UInt64(row)) + varint(UInt64(column)) + varint(UInt64(cells.count) << 1 | 1)
                let style = cells.first?.style ?? .plain
                out += color(style.fg) + color(style.bg) + varint(UInt64(style.attrs))
                for cell in cells {
                    let bytes = Array(cell.text.utf8)
                    if bytes.isEmpty {
                        out.append(2)
                    } else if bytes.count == 1, (0x20...0x7E).contains(bytes[0]) {
                        out.append(bytes[0])
                    } else {
                        out += [1] + varint(UInt64(bytes.count)) + bytes
                    }
                }
            case let .clear(row, column, count):
                out += varint(UInt64(row)) + varint(UInt64(column)) + varint(UInt64(count) << 1)
            }
        }
        return Data(out)
    }

    /// A lean frame that follows the last one: a scroll of `shift`, `clears` (row, column,
    /// count), and the cursor at `cursor` when given.
    static func leanFollowing(shift: Int = 0, clears: [(Int, Int, Int)] = [], cursor: (Int, Int)? = nil) -> Data {
        var out = varint(cursor == nil ? 0 : (1 << 3) | (1 << 4))
        if let cursor { out += varint(UInt64(cursor.0)) + varint(UInt64(cursor.1)) }
        out += varint(zigzag(shift)) + varint(UInt64(clears.count))
        for (row, column, count) in clears {
            out += varint(UInt64(row)) + varint(UInt64(column)) + varint(UInt64(count) << 1)
        }
        return Data(out)
    }

    /// A lean keyframe of stream `stream` (`columns` x `rows`, frame `frame`, cursor 0,0 shown)
    /// whose one span sets `cells` at `row`, `column`, with a fresh style table.
    static func leanKeyframe(stream: String, columns: Int, rows: Int, frame: Int, row: Int, column: Int,
                             cells: [AgentCLIHybridFrame.Cell]) -> Data {
        var out = varint(1 | 2 | 4 | 8 | 16) + varint(UInt64(stream.utf8.count)) + Array(stream.utf8)
        out += varint(UInt64(columns)) + varint(UInt64(rows)) + varint(UInt64(frame)) + varint(0) + varint(0)
        out += varint(0) + varint(1)
        out += varint(UInt64(row)) + varint(UInt64(column)) + varint(UInt64(cells.count) << 1 | 1)
        let style = cells.first?.style ?? .plain
        out += varint(0) + color(style.fg) + color(style.bg) + varint(UInt64(style.attrs))
        for cell in cells {
            let bytes = Array(cell.text.utf8)
            if bytes.isEmpty {
                out.append(0)
            } else if bytes.count == 1, (0x20...0x7E).contains(bytes[0]) {
                out.append(bytes[0])
            } else {
                out += [1] + varint(UInt64(bytes.count)) + bytes
            }
        }
        return Data(out)
    }

    /// v1 deltas whose varints sit at the edge of `UInt64` and `Int`, each with what it tries:
    /// the phone must fall back on every one, never trap.
    static let extremeDeltas: [(name: String, delta: Data)] = {
        let max = UInt64.max
        let intMax = UInt64(Int.max)
        func delta(_ values: [UInt64], _ tail: [UInt8] = []) -> Data { Data(values.flatMap(varint) + tail) }
        let oneCell: [UInt64] = [0, 0, 0, 1, 0, 0, 1 << 1 | 1]
        return [
            ("shift Int.min", delta([0, 0, max, 0])),
            ("clear at row UInt64.max", delta([0, 0, 0, 1, max, 0, 2 << 1])),
            ("clear at column UInt64.max", delta([0, 0, 0, 1, 0, max, 2 << 1])),
            ("clear of Int.max cells", delta([0, 0, 0, 1, 0, 0, max - 1])),
            ("set span of Int.max cells", delta([0, 0, 0, 1, 0, 0, max])),
            ("attrs UInt64.max", delta(oneCell, [0, 0] + varint(max) + [0x78])),
            ("cell text Int.max bytes long", delta(oneCell, [0, 0, 0, 1] + varint(intMax))),
            ("cell text UInt64.max bytes long", delta(oneCell, [0, 0, 0, 1] + varint(max))),
        ]
    }()

    /// Lean frames of the same kind, each one line (a keyframe of `stream`, `columns` x `rows`).
    static func extremeLeanFrames(stream: String, columns: Int, rows: Int) -> [(name: String, frame: Data)] {
        let intMax = UInt64(Int.max)
        let head = varint(1 | 2 | 4)
        func keyframe(_ tail: [UInt8]) -> Data {
            Data(head + varint(UInt64(stream.utf8.count)) + Array(stream.utf8) + varint(UInt64(columns))
                 + varint(UInt64(rows)) + varint(1) + varint(0) + varint(1) + tail)
        }
        // A span at 0,0 of two cells in a new plain style.
        let span = varint(0) + varint(0) + varint(2 << 1 | 1) + varint(0) + [0, 0] + varint(0)
        return [
            ("stream name Int.max bytes long", Data(head + varint(intMax))),
            ("run of Int.max cells", keyframe(span + [2] + varint(intMax) + [0x78])),
            ("cell text Int.max bytes long", keyframe(span + [1] + varint(intMax))),
            ("cell text UInt64.max bytes long", keyframe(span + [1] + varint(UInt64.max))),
            ("span at row UInt64.max", keyframe(varint(UInt64.max) + varint(0) + varint(2 << 1))),
        ]
    }

    static func leanLine(_ bytes: Data, surface: Int = 1) -> Data {
        line(["event": "agent-cli-lean", "surface": surface, "f": bytes.base64EncodedString()])
    }

    static func v1Line(_ step: HybridParityFixture.Step, stream: String, delta: Data? = nil, base: Int?? = nil,
                       frame: Int? = nil, cursor: (Int, Int)? = nil) -> Data {
        var object: [String: Any] = [
            "event": "agent-cli-frame", "surface": 1, "stream": stream, "frame": frame ?? step.frame,
            "cols": step.columns, "rows": step.rows, "data": (delta ?? step.delta).base64EncodedString(),
            "cursor_x": cursor?.0 ?? step.cursor.x, "cursor_y": cursor?.1 ?? step.cursor.y,
            "cursor_visible": step.cursor.visible,
        ]
        if let base = base ?? step.base { object["base"] = base }
        return line(object)
    }

    static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}
