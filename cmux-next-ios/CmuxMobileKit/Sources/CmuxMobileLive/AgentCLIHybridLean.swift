import Foundation

/// Reads the daemon's lean frames (`agent-cli-lean`, `agent-cli-hybrid-v2`): the same frames
/// as `agent-cli-frame`, packed so an agent CLI's screen costs the phone's link fewer bytes than
/// its PTY. A port of cmux-tui's `cmux_agent_cli_render::lean::LeanDecoder`.
///
/// A lean frame leaves out what this attach already sent: the stream id and the size come only
/// with the first frame, a keyframe or a resize; a frame that follows the last one carries no
/// number; the cursor comes only when it moved; a span names its style by index into a table
/// the attach builds as it goes. So one decoder reads one attach, from its first frame (a new
/// attach starts a new one, as the daemon starts a new encoder).
struct AgentCLIHybridLeanDecoder: Sendable {
    private static let keyframe: UInt64 = 1
    private static let head: UInt64 = 1 << 1
    private static let numbered: UInt64 = 1 << 2
    private static let cursor: UInt64 = 1 << 3
    private static let cursorVisible: UInt64 = 1 << 4

    private var styles: [AgentCLIHybridFrame.Style] = []
    private var stream = ""
    private var columns = 0
    private var rows = 0
    private var last: Int?
    private var cursorX = 0
    private var cursorY = 0

    /// The frame `bytes` carries; nil when they are not a lean frame this attach can read
    /// (then the decoder is left as it was).
    mutating func decode(_ bytes: Data) -> AgentCLIHybridFrame? {
        var next = self
        guard let frame = next.read(AgentCLIHybridFrame.Reader(bytes: [UInt8](bytes))) else { return nil }
        self = next
        return frame
    }

    private mutating func read(_ reader: AgentCLIHybridFrame.Reader) -> AgentCLIHybridFrame? {
        var reader = reader
        guard let flags = reader.varint() else { return nil }
        if flags & Self.head != 0 {
            guard let length = reader.varint().flatMap(Int.init(exactly:)),
                  length <= reader.bytes.count - reader.position,
                  let stream = String(bytes: reader.bytes[reader.position..<reader.position + length], encoding: .utf8)
            else { return nil }
            reader.position += length
            guard let columns = reader.varint(), let rows = reader.varint(), columns > 0, rows > 0,
                  columns <= UInt64(UInt16.max), rows <= UInt64(UInt16.max) else { return nil }
            self.stream = stream
            self.columns = Int(columns)
            self.rows = Int(rows)
        } else if last == nil {
            return nil
        }
        let number: Int
        let base: Int?
        if flags & Self.numbered != 0 {
            guard let value = reader.varint().flatMap(Int.init(exactly:)) else { return nil }
            number = value
            if flags & Self.keyframe != 0 {
                base = nil
            } else {
                guard let value = reader.varint().flatMap(Int.init(exactly:)) else { return nil }
                base = value
            }
        } else {
            guard let last, last < Int.max else { return nil }
            number = last + 1
            base = last
        }
        if flags & Self.cursor != 0 {
            guard let x = reader.varint(), let y = reader.varint(),
                  x <= UInt64(UInt16.max), y <= UInt64(UInt16.max) else { return nil }
            cursorX = Int(x)
            cursorY = Int(y)
        }
        guard let zigzag = reader.varint(), zigzag <= UInt64(UInt16.max), let count = reader.varint() else { return nil }
        let shift = Int(zigzag >> 1) ^ -Int(zigzag & 1)
        var spans: [AgentCLIHybridFrame.Span] = []
        for _ in 0..<count {
            guard let row = reader.varint(), let column = reader.varint(), let length = reader.varint(),
                  row <= UInt64(UInt16.max), column <= UInt64(UInt16.max), length >> 1 <= UInt64(UInt16.max)
            else { return nil }
            let width = Int(length >> 1)
            if length & 1 == 0 {
                spans.append(.clear(row: Int(row), column: Int(column), count: width))
                continue
            }
            guard let style = readStyle(&reader) else { return nil }
            var cells: [AgentCLIHybridFrame.Cell] = []
            cells.reserveCapacity(width)
            while cells.count < width {
                if reader.position < reader.bytes.count, reader.bytes[reader.position] == 2 {
                    reader.position += 1
                    guard let times = reader.varint().flatMap(Int.init(exactly:)), times > 0,
                          times <= width - cells.count, let text = Self.text(&reader) else { return nil }
                    cells.append(contentsOf: repeatElement(AgentCLIHybridFrame.Cell(text: text, style: style), count: times))
                } else {
                    guard let text = Self.text(&reader) else { return nil }
                    cells.append(AgentCLIHybridFrame.Cell(text: text, style: style))
                }
            }
            spans.append(.set(row: Int(row), column: Int(column), cells: cells))
        }
        guard reader.position == reader.bytes.count else { return nil }
        last = number
        return AgentCLIHybridFrame(
            stream: stream, frame: number, base: base, columns: columns, rows: rows,
            delta: AgentCLIHybridFrame.Delta(shift: shift, spans: spans),
            cursorX: cursorX, cursorY: cursorY, cursorVisible: flags & Self.cursorVisible != 0
        )
    }

    private mutating func readStyle(_ reader: inout AgentCLIHybridFrame.Reader) -> AgentCLIHybridFrame.Style? {
        guard let index = reader.varint().flatMap(Int.init(exactly:)) else { return nil }
        if index < styles.count { return styles[index] }
        guard index == styles.count, let fg = reader.color(), let bg = reader.color(),
              let attrs = reader.varint(), attrs <= UInt64(UInt16.max) else { return nil }
        let style = AgentCLIHybridFrame.Style(fg: fg, bg: bg, attrs: Int(attrs))
        styles.append(style)
        return style
    }

    /// A cell: printable ASCII is itself, 0 the empty half of a wide glyph, 1 other text.
    private static func text(_ reader: inout AgentCLIHybridFrame.Reader) -> String? {
        guard let tag = reader.byte() else { return nil }
        switch tag {
        case 0x20...0x7E: return String(UnicodeScalar(tag))
        case 0: return ""
        case 1:
            guard let length = reader.varint().flatMap(Int.init(exactly:)),
                  length <= reader.bytes.count - reader.position else { return nil }
            defer { reader.position += length }
            return String(bytes: reader.bytes[reader.position..<reader.position + length], encoding: .utf8)
        default: return nil
        }
    }
}
