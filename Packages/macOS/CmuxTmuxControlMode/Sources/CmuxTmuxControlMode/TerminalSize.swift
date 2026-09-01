import Foundation

/// A terminal size in character cells and, when known, physical cell metrics.
/// The cell metrics are ignored by tmux and cmux-tui, but Herdr uses them for
/// pixel-aware mouse mapping and Kitty graphics. Zero means that the local
/// renderer does not have a reliable metric yet.
public struct TerminalSize: Equatable, Sendable {
    public struct Grid: Equatable, Sendable {
        public let columns: Int
        public let rows: Int

        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }
    }

    public var columns: Int
    public var rows: Int
    public var cellWidthPixels: Int
    public var cellHeightPixels: Int

    public init(
        columns: Int,
        rows: Int,
        cellWidthPixels: Int = 0,
        cellHeightPixels: Int = 0
    ) {
        // tmux refuses sizes below 1x1; clamp so we never emit a malformed
        // refresh-client command.
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.cellWidthPixels = max(0, cellWidthPixels)
        self.cellHeightPixels = max(0, cellHeightPixels)
    }

    /// Whether both physical cell dimensions are trustworthy enough for a
    /// pixel-aware source. Sending one dimension without the other would make
    /// coordinate mapping inconsistent, so callers treat this as all-or-none.
    public var hasCellMetrics: Bool {
        cellWidthPixels > 0 && cellHeightPixels > 0
    }

    public var grid: Grid { Grid(columns: columns, rows: rows) }
}
