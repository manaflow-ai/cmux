extension MobileTerminalRenderGridFrame.Cursor {
    enum CodingKeys: String, CodingKey {
        case row, column, visible, location, style, blinking
        case activeRow = "active_row"
    }

    /// Encodes cursor metadata using the render-grid wire keys.
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

    /// The cursor's position relative to the exported viewport.
    public enum Location: String, Codable, Equatable, Sendable {
        /// The cursor lies inside the exported viewport.
        case viewport
        /// The cursor lies before the exported viewport.
        case aboveViewport = "above_viewport"
        /// The cursor lies after the exported viewport.
        case belowViewport = "below_viewport"
    }

    /// The terminal cursor shape captured by the render-grid producer.
    public enum Style: String, Codable, Equatable, Sendable {
        /// A filled block cursor.
        case block
        /// A vertical bar cursor.
        case bar
        /// An underline cursor.
        case underline
        /// A hollow block cursor.
        case blockHollow = "block_hollow"
    }
}
