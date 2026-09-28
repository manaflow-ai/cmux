import GhosttyKit

/// A semantic terminal text region that can be captured from Ghostty.
public enum TerminalTextRegion: Sendable, Equatable {
    /// The currently visible viewport.
    case viewport
    /// The current terminal screen.
    case screen
    /// The complete surface history.
    case history
    /// The active screen or history region selected by Ghostty.
    case active
    /// One row of the visible viewport, counted from the top, read as its own
    /// cells: a soft-wrapped line is not joined with its neighbors, and a
    /// blank row reads as blank however little content the viewport holds.
    /// `columns` is the viewport width.
    case viewportRow(Int, columns: Int)

    /// The Ghostty selection that covers the region.
    var selection: ghostty_selection_s {
        switch self {
        case .viewport:
            Self.wholeRegion(GHOSTTY_POINT_VIEWPORT)
        case .screen:
            Self.wholeRegion(GHOSTTY_POINT_SCREEN)
        case .history:
            Self.wholeRegion(GHOSTTY_POINT_SURFACE)
        case .active:
            Self.wholeRegion(GHOSTTY_POINT_ACTIVE)
        case let .viewportRow(row, columns):
            ghostty_selection_s(
                top_left: Self.viewportCell(column: 0, row: row),
                bottom_right: Self.viewportCell(column: max(columns, 1) - 1, row: row),
                rectangle: false
            )
        }
    }

    private static func wholeRegion(_ tag: ghostty_point_tag_e) -> ghostty_selection_s {
        ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
    }

    private static func viewportCell(column: Int, row: Int) -> ghostty_point_s {
        ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_EXACT,
            x: UInt32(clamping: column),
            y: UInt32(clamping: row)
        )
    }
}
