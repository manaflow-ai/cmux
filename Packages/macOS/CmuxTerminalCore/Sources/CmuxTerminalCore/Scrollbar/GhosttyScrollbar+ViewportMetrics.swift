extension GhosttyScrollbar {
    /// Rows between the viewport's bottom edge and the live bottom.
    public var rowsBelowViewport: UInt64 {
        let visibleRows = min(total, len)
        let lastTopRow = total >= visibleRows ? total - visibleRows : 0
        let topRow = min(offset, lastTopRow)
        return lastTopRow - topRow
    }

    /// Whether the viewport reaches the live bottom of scrollback.
    public var isAtBottom: Bool {
        rowsBelowViewport == 0
    }
}
