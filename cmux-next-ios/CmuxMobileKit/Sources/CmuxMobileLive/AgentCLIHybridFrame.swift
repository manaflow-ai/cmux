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

    /// Whether this frame, applied on its base, moves no cell and no row: what it changes is at
    /// most the cursor (an equal refresh).
    var changesNoCell: Bool {
        guard base != nil, let delta else { return false }
        return delta.shift == 0 && delta.spans.isEmpty
    }

    /// The bytes that draw this frame on a terminal showing frame ``base`` (a blank one for a
    /// keyframe); nil when `data` is not a delta.
    ///
    /// No synchronized update (DEC mode 2026) around them, unlike cmux-tui's `frame_bytes`.
    /// Each `?2026h` woke Ghostty's IO thread and re-armed its 1 s reset timer, for every
    /// frame. A frame's bytes reach Ghostty in one `process_output`, parsed under the terminal
    /// lock, unless the screen's output queue (`TerminalOutputQueue`) splits them: only when
    /// more than one batch is waiting (256 KiB, or 16 KiB while the screen is dragged). Then
    /// one display frame can show part of the frame.
    var terminalBytes: Data? {
        guard let delta else { return nil }
        var out = "\u{1b}[?25l\u{1b}[0m"
        if base == nil { out += "\u{1b}[H\u{1b}[2J" }
        if delta.shift > 0 {
            // Line feeds on the last row: the rows that leave the top reach the scrollback.
            out += "\u{1b}[\(rows);1H" + String(repeating: "\n", count: delta.shift)
        } else if delta.shift < 0 {
            out += "\u{1b}[\(-delta.shift)T"
        }
        var style: Style?
        func use(_ want: Style) {
            if style != want {
                out += want.sgr
                style = want
            }
        }
        for span in delta.spans {
            switch span {
            case let .set(row, column, cells):
                out += "\u{1b}[\(row + 1);\(column + 1)H"
                // Whether the cursor stands at the next cell's column. After a glyph that is not
                // one ASCII character it may not: the phone's Ghostty gives it the width its own
                // Unicode tables say (🚀 and ✅ are wide there), so the next cell is placed by
                // column, and no width table here decides anything.
                var placed = true
                var skip = false
                for (index, cell) in cells.enumerated() {
                    let x = column + index
                    if skip {
                        skip = false
                        continue
                    }
                    let ascii = cell.text.utf8.count == 1 && (0x20...0x7E).contains(cell.text.utf8.first ?? 0)
                    if !ascii, !cell.text.isEmpty, index + 1 < cells.count, cells[index + 1].text.isEmpty {
                        // The empty cell right of a glyph first: a wide glyph then covers it, a
                        // narrow one leaves it blank. Which it is is Ghostty's to say.
                        out += "\u{1b}[\(row + 1);\(x + 2)H"
                        use(cells[index + 1].style)
                        out += " \u{1b}[\(row + 1);\(x + 1)H"
                        use(cell.style)
                        out += cell.text
                        skip = true
                        placed = false
                        continue
                    }
                    if !placed { out += "\u{1b}[\(row + 1);\(x + 1)H" }
                    use(cell.style)
                    if cell.text.isEmpty {
                        out += " "
                        placed = true
                        continue
                    }
                    out += cell.text
                    placed = ascii
                }
            case let .clear(row, column, count):
                use(.plain)
                out += "\u{1b}[\(row + 1);\(column + 1)H\u{1b}[\(count)X"
            }
        }
        out += "\u{1b}[0m\u{1b}[\(cursorY + 1);\(cursorX + 1)H"
        if cursorVisible { out += "\u{1b}[?25h" }
        return Data(out.utf8)
    }

    /// Why this frame cannot be drawn on a grid of its size, or nil when it can: every span
    /// inside the grid, the cursor on it, a scroll of at most its height, and no cell text that
    /// a terminal would read as a control (an ESC in a cell would draw what it says, not the
    /// cell). A frame that fails is never drawn: the attach falls back
    /// (``DaemonTerminalInbound/hybridFallback(reason:)``).
    var invalidReason: String? {
        guard let delta else { return "data is not a delta" }
        guard columns > 0, rows > 0, columns <= Int(UInt16.max), rows <= Int(UInt16.max) else { return "grid \(columns)x\(rows)" }
        guard delta.shift.magnitude <= UInt(rows) else { return "shift \(delta.shift) on \(rows) rows" }
        guard (0..<columns).contains(cursorX), (0..<rows).contains(cursorY) else { return "cursor \(cursorX),\(cursorY)" }
        for span in delta.spans {
            switch span {
            case let .set(row, column, cells):
                guard (0..<rows).contains(row), column >= 0, !cells.isEmpty, column + cells.count <= columns else {
                    return "span at \(row),\(column) of \(cells.count) cells"
                }
                for cell in cells where !Self.drawable(cell.text) {
                    return "a control character in a cell at row \(row)"
                }
            case let .clear(row, column, count):
                guard (0..<rows).contains(row), column >= 0, count > 0, column + count <= columns else {
                    return "clear at \(row),\(column) of \(count) cells"
                }
            }
        }
        return nil
    }

    /// Whether `text` is a cell's glyph: no C0 or C1 control, no DEL.
    static func drawable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            !(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value))
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
            // Every count, place and style is bounded before it becomes an Int: a frame the
            // phone cannot read falls back, it never traps.
            guard let seq = reader.varint(), let atMs = reader.varint(),
                  let zigzag = reader.varint(), zigzag >> 1 <= UInt64(UInt16.max), let count = reader.varint() else { return nil }
            self.seq = seq
            self.atMs = atMs
            shift = Int(zigzag >> 1) ^ -Int(zigzag & 1)
            var spans: [Span] = []
            for _ in 0..<count {
                guard let row = reader.varint(), let column = reader.varint(), let length = reader.varint(),
                      row <= UInt64(UInt16.max), column <= UInt64(UInt16.max), length >> 1 <= UInt64(UInt16.max)
                else { return nil }
                let count = Int(length >> 1)
                if length & 1 == 0 {
                    spans.append(.clear(row: Int(row), column: Int(column), count: count))
                    continue
                }
                guard let fg = reader.color(), let bg = reader.color(), let attrs = reader.varint(),
                      attrs <= UInt64(UInt16.max) else {
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

        /// An unsigned LEB128 value; nil when the bytes end first or it does not fit 64 bits.
        /// The tenth byte holds bit 63 alone: anything more (a higher bit, or an eleventh byte)
        /// is a value past 64 bits, which the shift would drop and read as a smaller one.
        mutating func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while let byte = byte() {
                if shift == 63, byte > 1 { return nil }
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
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
                guard let length = varint().flatMap(Int.init(exactly:)), length <= bytes.count - position else { return nil }
                defer { position += length }
                return String(bytes: bytes[position..<position + length], encoding: .utf8)
            default: return nil
            }
        }
    }
}
