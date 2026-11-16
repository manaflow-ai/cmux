import Foundation

/// One `agent-cli-frame` of the Mac's daemon (`agent-cli-hybrid-v1`): an agent CLI's
/// terminal (Claude Code, Codex, opencode) as the cells that changed, instead of its PTY
/// bytes (Leo, 2026-11-14: "can we still keep the current behaviour/appearance and not
/// stream").
///
/// The phone keeps drawing with its own terminal, so the Terminal face looks as it does from
/// the PTY: ``terminalBytes`` turns a frame into cursor moves, SGR and the changed cells'
/// text, the steps of `cmux_agent_cli_render::vt::frame_bytes` (cmux-tui), which the daemon's
/// tests check against a real Claude Code and Codex session cell for cell.
struct AgentCLIHybridFrame: Sendable, Equatable {
    /// The daemon's stream: an attach names it with ``frame`` to resume after a drop.
    let stream: String
    let frame: Int
    /// The frame this one applies on; nil for a keyframe (over a blank screen).
    let base: Int?
    let columns: Int
    let rows: Int
    /// The changed cells; nil when the event's `data` is not a delta.
    let delta: Delta?
    let cursorX: Int
    let cursorY: Int
    let cursorVisible: Bool

    init?(_ object: [String: Any]) {
        guard let stream = object["stream"] as? String,
              let frame = object["frame"] as? Int,
              let columns = object["cols"] as? Int, columns > 0,
              let rows = object["rows"] as? Int, rows > 0,
              let encoded = object["data"] as? String,
              let data = Data(base64Encoded: encoded) else { return nil }
        self.stream = stream
        self.frame = frame
        base = object["base"] as? Int
        self.columns = columns
        self.rows = rows
        delta = Delta(data)
        cursorX = object["cursor_x"] as? Int ?? 0
        cursorY = object["cursor_y"] as? Int ?? 0
        cursorVisible = object["cursor_visible"] as? Bool ?? false
    }

    /// A frame read from another form (a lean `agent-cli-lean` frame, ``AgentCLIHybridLeanDecoder``).
    init(stream: String, frame: Int, base: Int?, columns: Int, rows: Int, delta: Delta,
         cursorX: Int, cursorY: Int, cursorVisible: Bool) {
        self.stream = stream
        self.frame = frame
        self.base = base
        self.columns = columns
        self.rows = rows
        self.delta = delta
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.cursorVisible = cursorVisible
    }

    /// The bytes that draw this frame on a terminal showing frame ``base`` (a blank one for a
    /// keyframe); nil when `data` is not a delta.
    var terminalBytes: Data? {
        guard let delta else { return nil }
        var out = "\u{1b}[?2026h\u{1b}[?25l\u{1b}[0m"
        if base == nil { out += "\u{1b}[H\u{1b}[2J" }
        if delta.shift > 0 {
            // Line feeds on the last row: the rows that leave the top reach the scrollback.
            out += "\u{1b}[\(rows);1H" + String(repeating: "\n", count: delta.shift)
        } else if delta.shift < 0 {
            out += "\u{1b}[\(-delta.shift)T"
        }
        var style: Style?
        for span in delta.spans {
            switch span {
            case let .set(row, column, cells):
                out += "\u{1b}[\(row + 1);\(column + 1)H"
                var afterWide = false
                for cell in cells {
                    if style != cell.style {
                        out += cell.style.sgr
                        style = cell.style
                    }
                    if cell.text.isEmpty {
                        // The trailing half of a wide glyph: the cursor is past it already.
                        if !afterWide { out += " " }
                        afterWide = false
                        continue
                    }
                    out += cell.text
                    afterWide = Self.width(cell.text) == 2
                }
            case let .clear(row, column, count):
                if style != .plain {
                    out += "\u{1b}[0m"
                    style = .plain
                }
                out += "\u{1b}[\(row + 1);\(column + 1)H\u{1b}[\(count)X"
            }
        }
        out += "\u{1b}[0m\u{1b}[\(cursorY + 1);\(cursorX + 1)H"
        if cursorVisible { out += "\u{1b}[?25h" }
        out += "\u{1b}[?2026l"
        return Data(out.utf8)
    }

    /// Columns `text` takes, as `cmux_agent_cli_render::char_width` counts them.
    static func width(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            switch scalar.value {
            case 0x0300...0x036F, 0x200B...0x200F, 0xFE00...0xFE0F: total
            case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
                 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
                 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F,
                 0x1F900...0x1F9FF, 0x20000...0x3FFFD: total + 2
            default: total + 1
            }
        }
    }

    enum Color: Equatable, Sendable {
        case standard
        case palette(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    struct Style: Equatable, Sendable {
        var fg: Color
        var bg: Color
        var attrs: Int

        static let plain = Style(fg: .standard, bg: .standard, attrs: 0)

        /// SGR from a reset: the v7 attribute bits, the hybrid stream's underline bit
        /// (0x0100), then the colors.
        var sgr: String {
            var out = "\u{1b}[0"
            for (bit, code) in [(0x0001, "1"), (0x0010, "2"), (0x0002, "3"), (0x0100, "4"),
                                (0x0040, "5"), (0x0008, "7"), (0x0020, "8"), (0x0004, "9")]
                where attrs & bit != 0 {
                out += ";" + code
            }
            func color(_ color: Color, base: Int, bright: Int, extended: Int) {
                switch color {
                case .standard: break
                case .palette(let index) where index < 8: out += ";\(base + Int(index))"
                case .palette(let index) where index < 16: out += ";\(bright + Int(index) - 8)"
                case .palette(let index): out += ";\(extended);5;\(index)"
                case let .rgb(red, green, blue): out += ";\(extended);2;\(red);\(green);\(blue)"
                }
            }
            color(fg, base: 30, bright: 90, extended: 38)
            color(bg, base: 40, bright: 100, extended: 48)
            return out + "m"
        }
    }

    struct Cell: Equatable, Sendable {
        var text: String
        var style: Style
    }

    enum Span: Equatable, Sendable {
        case set(row: Int, column: Int, cells: [Cell])
        case clear(row: Int, column: Int, count: Int)
    }

    /// `cmux_agent_cli_render::hybrid::Delta::decode`.
    struct Delta: Equatable, Sendable {
        var seq: UInt64
        var atMs: UInt64
        var shift: Int
        var spans: [Span]

        init(shift: Int, spans: [Span]) {
            seq = 0
            atMs = 0
            self.shift = shift
            self.spans = spans
        }

        init?(_ bytes: Data) {
            var reader = Reader(bytes: [UInt8](bytes))
            guard let seq = reader.varint(), let atMs = reader.varint(),
                  let zigzag = reader.varint(), let count = reader.varint() else { return nil }
            self.seq = seq
            self.atMs = atMs
            shift = Int(zigzag >> 1) ^ -Int(zigzag & 1)
            var spans: [Span] = []
            for _ in 0..<count {
                guard let row = reader.varint(), let column = reader.varint(),
                      let length = reader.varint() else { return nil }
                let count = Int(length >> 1)
                if length & 1 == 0 {
                    spans.append(.clear(row: Int(row), column: Int(column), count: count))
                    continue
                }
                guard let fg = reader.color(), let bg = reader.color(), let attrs = reader.varint() else {
                    return nil
                }
                let style = Style(fg: fg, bg: bg, attrs: Int(attrs))
                var cells: [Cell] = []
                cells.reserveCapacity(count)
                for _ in 0..<count {
                    guard let text = reader.text() else { return nil }
                    cells.append(Cell(text: text, style: style))
                }
                spans.append(.set(row: Int(row), column: Int(column), cells: cells))
            }
            guard reader.position == reader.bytes.count else { return nil }
            self.spans = spans
        }
    }

    struct Reader {
        let bytes: [UInt8]
        var position = 0

        mutating func byte() -> UInt8? {
            guard position < bytes.count else { return nil }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while let byte = byte() {
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        mutating func color() -> Color? {
            switch byte() {
            case 0: return .standard
            case 1: return byte().map(Color.palette)
            case 2:
                guard let red = byte(), let green = byte(), let blue = byte() else { return nil }
                return .rgb(red, green, blue)
            default: return nil
            }
        }

        mutating func text() -> String? {
            guard let tag = byte() else { return nil }
            switch tag {
            case 0x20...0x7E: return String(UnicodeScalar(tag))
            case 2: return ""
            case 1:
                guard let length = varint(), position + Int(length) <= bytes.count else { return nil }
                defer { position += Int(length) }
                return String(bytes: bytes[position..<position + Int(length)], encoding: .utf8)
            default: return nil
            }
        }
    }
}
