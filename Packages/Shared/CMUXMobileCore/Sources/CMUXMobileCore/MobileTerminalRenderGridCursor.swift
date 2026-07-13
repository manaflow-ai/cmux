extension MobileTerminalRenderGridFrame.Cursor {
    enum CodingKeys: String, CodingKey {
        case row, column, visible, location, style, blinking
        case activeRow = "active_row"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(row, forKey: .row)
        try container.encode(column, forKey: .column)
        try container.encode(visible, forKey: .visible)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(activeRow, forKey: .activeRow)
        try container.encode(style, forKey: .style)
        try container.encode(blinking, forKey: .blinking)
    }

    func validate(columns: Int, rows: Int) throws {
        guard (0..<rows).contains(row), (0..<columns).contains(column) else {
            throw MobileTerminalRenderGridError.invalidCursor(row: row, column: column)
        }
        if let activeRow, !(0..<rows).contains(activeRow) {
            throw MobileTerminalRenderGridError.invalidCursor(row: activeRow, column: column)
        }
    }

    public enum Location: String, Codable, Equatable, Sendable {
        case viewport
        case aboveViewport = "above_viewport"
        case belowViewport = "below_viewport"
    }

    public enum Style: String, Codable, Equatable, Sendable {
        case block
        case bar
        case underline
        case blockHollow = "block_hollow"
    }
}
