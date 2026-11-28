public import Foundation

/// The daemon's render-mode attach events (`cmux-tui/spec/render.md`):
/// `render-state` (complete viewport) and `render-delta` (dirty rows).
/// Decoded leniently: unknown fields (graphics, future additions) are ignored.
public struct DaemonRenderFrame: Sendable, Equatable, Decodable {
    public struct Size: Sendable, Equatable, Decodable {
        public var cols: Int
        public var rows: Int
    }

    public struct Cursor: Sendable, Equatable, Decodable {
        public var x: Int
        public var y: Int
        public var style: String
        public var blink: Bool
        public var visible: Bool
        public var color: String?
    }

    public struct Run: Sendable, Equatable, Decodable {
        public var text: String
        public var fg: String?
        public var bg: String?
        public var attrs: UInt16
        public var underline: String?
        public var widthHint: Int?

        enum CodingKeys: String, CodingKey {
            case text, fg, bg, attrs, underline
            case widthHint = "width_hint"
        }

        /// Grid columns this run covers. The daemon sends `width_hint`
        /// whenever a wide grapheme makes `text` ambiguous; otherwise one
        /// grapheme is one cell.
        public var cellWidth: Int { widthHint ?? text.count }
    }

    public struct Row: Sendable, Equatable, Decodable {
        public var row: Int
        public var runs: [Run]
    }

    public var event: String
    public var surface: UInt64?
    /// Present on `render-state` and on a resizing `render-delta`.
    public var size: Size?
    public var cursor: Cursor
    public var defaultFG: String?
    public var defaultBG: String?
    public var scrollbackRows: Int?
    public var historyEpoch: UInt64?
    /// `render-delta` only; `render-state` is always complete.
    public var full: Bool?
    public var rows: [Row]

    enum CodingKeys: String, CodingKey {
        case event, surface, size, cursor, full, rows
        case defaultFG = "default_fg"
        case defaultBG = "default_bg"
        case scrollbackRows = "scrollback_rows"
        case historyEpoch = "history_epoch"
    }

    /// True for `render-state` and full deltas: `rows` is the whole viewport.
    public var isComplete: Bool { event == "render-state" || full == true }
}

/// `attrs` bits from render.md.
enum DaemonRenderAttribute {
    static let bold: UInt16 = 0x0001
    static let italic: UInt16 = 0x0002
    static let strikethrough: UInt16 = 0x0004
    static let inverse: UInt16 = 0x0008
    static let faint: UInt16 = 0x0010
    static let invisible: UInt16 = 0x0020
    static let blink: UInt16 = 0x0040
}
