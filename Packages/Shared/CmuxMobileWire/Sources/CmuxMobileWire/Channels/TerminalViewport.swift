/// The cells a viewer can show (ghostty-next.md section 6). Reported once per
/// gesture end; the software keyboard never changes it.
public struct TerminalViewport: Hashable, Sendable, Codable {
    public var cols: Int
    public var rows: Int
    public var pxWidth: Int?
    public var pxHeight: Int?

    public init(cols: Int, rows: Int, pxWidth: Int? = nil, pxHeight: Int? = nil) {
        self.cols = cols
        self.rows = rows
        self.pxWidth = pxWidth
        self.pxHeight = pxHeight
    }

    enum CodingKeys: String, CodingKey {
        case cols, rows
        case pxWidth = "px_width"
        case pxHeight = "px_height"
    }
}
