/// Ghostty's row numberings, one type each, so they cannot be mixed
/// (termqa round 8).
///
/// - `TerminalAbsoluteRow`: the scrollbar's numbering. 0 is the oldest row
///   Ghostty keeps, `totalRows` is the scrollbar's total. The document, the
///   scroll model and the reading mark count in it.
/// - `TerminalViewportRow`: `GHOSTTY_POINT_VIEWPORT` y, 0 = the top row of
///   Ghostty's viewport (the surface's first row).
/// - `TerminalActiveRow`: `GHOSTTY_POINT_ACTIVE` y, 0 = the top row of the
///   active area (the bottom `gridRows` rows, where the cursor always is).
/// - `TerminalScreenRow`: `GHOSTTY_POINT_SCREEN` y. It counts from the same
///   oldest row as the scrollbar, but Ghostty's C API clamps every exact
///   point's y to `gridRows - 1` (`embedded.zig`, `Point.pin`), so only the
///   first `gridRows` rows can be addressed: a screen y of 500 on a 151-row
///   surface reads row 150 (round 8 probe: screen y 151, 908 and 1058 all
///   read the same row). Round 7's helpers passed absolute rows as screen y,
///   so after `clear` the rows below the prompt read as that old row, the
///   document kept the 150 blank rows of the active area, and the page
///   showed blank rows with the prompt off screen.
///
/// The Ghostty-addressable types are made only by `TerminalRowSpace`, which
/// returns nil for an absolute row Ghostty cannot address, never another row.
public struct TerminalAbsoluteRow: Hashable, Comparable, Sendable {
    public var index: Int
    public init(_ index: Int) { self.index = index }
    public static func < (a: Self, b: Self) -> Bool { a.index < b.index }
}

public struct TerminalViewportRow: Hashable, Sendable {
    public let index: Int
    fileprivate init(_ index: Int) { self.index = index }
}

public struct TerminalActiveRow: Hashable, Sendable {
    public let index: Int
    fileprivate init(_ index: Int) { self.index = index }
}

public struct TerminalScreenRow: Hashable, Sendable {
    public let index: Int
    fileprivate init(_ index: Int) { self.index = index }
}

/// Reads one Ghostty row by each addressable numbering (the surface view;
/// a model of Ghostty's C API in tests). Each read is one row's plain text.
@MainActor
public protocol TerminalRowTextSource {
    func text(_ row: TerminalViewportRow) -> String?
    func text(_ row: TerminalActiveRow) -> String?
    func text(_ row: TerminalScreenRow) -> String?
    /// Plain text of screen rows `0...last` in one read (Ghostty writes one
    /// newline per blank row before the first row with text).
    func text(screenRowsThrough last: TerminalScreenRow) -> String?
}

/// The numberings at one moment: the scrollbar's total, the surface's grid
/// rows and the viewport's top (the scrollbar's offset).
public struct TerminalRowSpace: Equatable, Sendable {
    public var totalRows: Int
    public var gridRows: Int
    public var viewportTop: Int

    public init(totalRows: Int, gridRows: Int, viewportTop: Int) {
        self.totalRows = max(0, totalRows)
        self.gridRows = max(0, gridRows)
        self.viewportTop = max(0, viewportTop)
    }

    /// First absolute row of the active area.
    public var activeTop: Int { max(0, totalRows - gridRows) }

    public func contains(_ row: TerminalAbsoluteRow) -> Bool { row.index >= 0 && row.index < totalRows }

    public func active(_ row: TerminalAbsoluteRow) -> TerminalActiveRow? {
        guard contains(row) else { return nil }
        let y = row.index - activeTop
        return y >= 0 && y < gridRows ? TerminalActiveRow(y) : nil
    }

    public func viewport(_ row: TerminalAbsoluteRow) -> TerminalViewportRow? {
        guard contains(row) else { return nil }
        let y = row.index - viewportTop
        return y >= 0 && y < gridRows ? TerminalViewportRow(y) : nil
    }

    /// A screen row only where Ghostty does not clamp it: the first `gridRows` rows.
    public func screen(_ row: TerminalAbsoluteRow) -> TerminalScreenRow? {
        guard contains(row), row.index < gridRows else { return nil }
        return TerminalScreenRow(row.index)
    }

    /// The viewport row `y` (0 = the surface's first row), when it is on the grid.
    public func viewportRow(_ y: Int) -> TerminalViewportRow? {
        y >= 0 && y < gridRows ? TerminalViewportRow(y) : nil
    }

    public func absolute(_ row: TerminalViewportRow) -> TerminalAbsoluteRow { TerminalAbsoluteRow(viewportTop + row.index) }
    public func absolute(_ row: TerminalActiveRow) -> TerminalAbsoluteRow { TerminalAbsoluteRow(activeTop + row.index) }
    public func absolute(_ row: TerminalScreenRow) -> TerminalAbsoluteRow { TerminalAbsoluteRow(row.index) }
}

/// Absolute-row reads over a `TerminalRowTextSource`: each row goes to
/// Ghostty in a numbering that addresses it (the active area, else the
/// viewport, else the screen's first rows), or is not read at all.
@MainActor
public struct TerminalRowReader {
    public var space: TerminalRowSpace
    public var source: any TerminalRowTextSource

    public init(space: TerminalRowSpace, source: any TerminalRowTextSource) {
        self.space = space
        self.source = source
    }

    /// One absolute row's text; nil when Ghostty cannot address it now.
    public func text(_ row: TerminalAbsoluteRow) -> String? {
        if let active = space.active(row) { return source.text(active) }
        if let viewport = space.viewport(row) { return source.text(viewport) }
        if let screen = space.screen(row) { return source.text(screen) }
        return nil
    }

    /// The lowest row with text in `top...bottom`, reading from the bottom:
    /// the rows an inline TUI draws below its cursor. Rows Ghostty cannot
    /// address are skipped. Nil when every row read is blank.
    public func lastNonBlankRow(from top: TerminalAbsoluteRow, through bottom: TerminalAbsoluteRow) -> TerminalAbsoluteRow? {
        guard top <= bottom else { return nil }
        for index in stride(from: bottom.index, through: top.index, by: -1) {
            let row = TerminalAbsoluteRow(index)
            guard let text = text(row) else { continue }
            if text.contains(where: { $0 != " " && $0 != "\n" && $0 != "\r" && $0 != "\t" }) { return row }
        }
        return nil
    }

    /// Blank rows at the top of the screen, through `last` (absolute): the
    /// mirror's rows above the Mac's screen that nothing wrote. Only the
    /// first `gridRows` rows are addressable, so the count is at most
    /// `gridRows` (an all-blank read of a longer range reports the rows read).
    public func leadingBlankRows(through last: TerminalAbsoluteRow) -> Int? {
        guard last.index >= 0, space.totalRows > 0, space.gridRows > 0 else { return nil }
        let capped = TerminalAbsoluteRow(min(last.index, space.totalRows - 1, space.gridRows - 1))
        guard let screenLast = space.screen(capped), let text = source.text(screenRowsThrough: screenLast) else { return nil }
        let limit = capped.index + 1
        guard !text.isEmpty else { return limit }
        return Array(text.utf8).withUnsafeBytes { TerminalDocumentLayout.leadingNewlines(in: $0, limit: limit) }
    }
}
