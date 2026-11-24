import CoreGraphics

/// How the phone shows the Mac's grid when it is not the phone's own
/// (PROTOCOL.md "Terminal sizing policy", "A grid larger than the phone").
///
/// The Mac's sizing policy can keep a shared terminal at another device's
/// grid (this Mac's pane under Prefer this Mac, a smaller phone under Fit the
/// smallest viewer). The phone then renders that grid exactly, at its own
/// font size: its mirror (the Ghostty surface) gets the Mac's columns, so a
/// line is never rewrapped at the phone's width (that garbled every TUI).
///
/// - Wider than the phone: the mirror is wider than the page and pans
///   sideways (`maxPanX`, `pan(toShowColumn:from:)`).
/// - Narrower than the phone: the grid sits at the leading edge.
/// - Fewer rows than the phone's TUI area: the grid is pinned to the top and
///   the rest is letterboxed (`letterbox`).
/// - More rows than the TUI area: the TUI is clipped and shifted only far
///   enough to keep the cursor row on screen (`rowShift(keeping:from:)`),
///   and while it is shifted its first rows (Claude Code's header box) stay
///   pinned at the top of the area (`rowPlacement(keeping:from:headerRows:)`).
///
/// The phone still claims its own grid (`resize-surface`); only the
/// rendering follows the Mac's. Pure geometry; the controller applies it.
public struct TerminalHostGridLayout: Equatable, Sendable {
    /// The page's visible grid width in points (the page minus its side padding).
    public var viewportWidth: CGFloat
    public var cell: CGSize
    /// The screen scale, for the largest surface Metal draws.
    public var scale: CGFloat
    /// The Mac's grid (`vt-state`, `resized`); nil before the first attach
    /// or for a local session: the phone's own grid.
    public var hostColumns: Int?
    public var hostRows: Int?
    /// The phone's TUI rows (toolbar to composer).
    public var visibleRows: Int
    /// Wide (the key row's Wide key; Leo, 2026-11-23: "we necessarily need
    /// logic for you to be able to like 'horizontally scroll'"): the phone's
    /// own grid is this many columns, more than the page fits, so a wide
    /// table or a long line stays one row and the page pans sideways to it.
    /// Nil: the phone's grid is the page's width.
    public var wideColumns: Int?

    /// Wide's columns: as wide as a wide Mac window, and well inside the
    /// widest surface the phone draws (about 340 columns at 3x).
    public static let defaultWideColumns = 200

    /// Widest surface Ghostty's layer draws (as `TerminalMirrorRows`: 8192 px).
    static let maxSurfacePixels: CGFloat = 8192
    /// Cells kept between the cursor and the edge it pans toward.
    static let cursorMargin = 4

    public init(viewportWidth: CGFloat, cell: CGSize, scale: CGFloat, hostColumns: Int?, hostRows: Int?, visibleRows: Int,
                wideColumns: Int? = nil) {
        self.viewportWidth = viewportWidth
        self.cell = cell
        self.scale = scale
        self.hostColumns = hostColumns
        self.hostRows = hostRows
        self.visibleRows = visibleRows
        self.wideColumns = wideColumns
    }

    /// The Mac's columns the mirror follows: none on the primary screen while
    /// the Mac's grid is the phone's own claim (sent or still on its way).
    /// A zoom key changes the phone's columns at once and its claim reaches
    /// the Mac a settle and a round trip later; followed meanwhile, the
    /// mirror took the old count at the new cell width (wider than the page,
    /// panning sideways, or narrower at its leading edge) and Ghostty
    /// rewrapped the rows twice more: to the old count, then to the new one
    /// when the Mac answered. A full-screen app keeps the Mac's grid until it
    /// redraws (the alternate screen does not rewrap).
    public static func followedHostColumns(remoteColumns: Int?, gridIsPhonesOwn: Bool, alternateScreen: Bool) -> Int? {
        if gridIsPhonesOwn, !alternateScreen { return nil }
        return remoteColumns
    }

    /// Columns the page fits at the phone's font size.
    public var phoneColumns: Int {
        cell.width > 0 ? max(1, Int(floor(viewportWidth / cell.width))) : 0
    }

    /// The most columns the widest surface draws at this cell width.
    private var widestColumns: Int {
        max(1, Int(floor(Self.maxSurfacePixels / (cell.width * max(1, scale)))))
    }

    /// The grid the phone claims as its own: the page's columns, or Wide's
    /// when Wide is on and it is more (capped to the widest surface).
    public var ownColumns: Int {
        guard let wideColumns, cell.width > 0 else { return phoneColumns }
        return max(phoneColumns, min(wideColumns, widestColumns))
    }

    /// Whether the phone's own grid is wider than the page (Wide is on).
    public var isWide: Bool { ownColumns > phoneColumns }

    /// The mirror's columns: the Mac's (capped to the widest surface), else the phone's own.
    public var columns: Int {
        guard let hostColumns, hostColumns > 0, cell.width > 0 else { return ownColumns }
        return min(hostColumns, widestColumns)
    }

    /// The Mac's grid is wider than the widest surface the phone draws
    /// (about 390 columns at 3x): the mirror shows only its first
    /// ``columns`` and the note says so (lines past them wrap on the phone).
    public var isCapped: Bool {
        guard let hostColumns else { return false }
        return columns < hostColumns
    }

    /// Whether the mirror is not the phone's own width.
    public var followsHost: Bool { columns != phoneColumns }

    /// The mirror's width. Ghostty fits `floor(width / cell)` columns (no
    /// padding), so half a cell more makes exactly `columns`, whatever the
    /// pixel rounding. The phone's own grid at the page's width keeps the
    /// page's width.
    public var surfaceWidth: CGFloat {
        guard followsHost else { return viewportWidth }
        return (CGFloat(columns) + 0.5) * cell.width
    }

    /// How far the mirror pans sideways (0: it fits).
    public var maxPanX: CGFloat {
        max(0, CGFloat(columns) * cell.width - viewportWidth)
    }

    public func clampPan(_ x: CGFloat) -> CGFloat {
        min(max(0, x), maxPanX)
    }

    /// The smallest pan from `current` that shows `column` with
    /// ``cursorMargin`` cells beside it (as far as the grid allows).
    public func pan(toShowColumn column: Int, from current: CGFloat) -> CGFloat {
        guard maxPanX > 0, cell.width > 0 else { return 0 }
        let margin = CGFloat(Self.cursorMargin) * cell.width
        let left = CGFloat(max(0, column)) * cell.width
        let right = left + cell.width
        var pan = clampPan(current)
        if left - margin < pan {
            pan = left - margin
        } else if right + margin > pan + viewportWidth {
            pan = right + margin - viewportWidth
        }
        return clampPan(pan)
    }

    /// The TUI area below a grid with fewer rows than the phone's (nil: none).
    /// `top` and `height` are in points from the grid's top.
    public var letterbox: (top: CGFloat, height: CGFloat)? {
        guard let hostRows, hostRows > 0, hostRows < visibleRows, cell.height > 0 else { return nil }
        return (CGFloat(hostRows) * cell.height, CGFloat(visibleRows - hostRows) * cell.height)
    }

    /// Rows a TUI taller than the phone's area is shifted up, from
    /// `current`, so `cursorRow` (a viewport row; nil: unknown) is on screen.
    /// It moves only when the cursor would be off screen.
    public func rowShift(keeping cursorRow: Int?, from current: Int) -> Int {
        guard let hostRows, visibleRows > 0, hostRows > visibleRows else { return 0 }
        let most = hostRows - visibleRows
        var shift = min(max(0, current), most)
        guard let cursorRow else { return shift }
        if cursorRow < shift {
            shift = cursorRow
        } else if cursorRow >= shift + visibleRows {
            shift = cursorRow - visibleRows + 1
        }
        return min(max(0, shift), most)
    }

    /// Where a TUI taller than the phone's area sits: its shift, and how many
    /// of its first rows stay pinned at the top of the area while shifted.
    public struct RowPlacement: Equatable, Sendable {
        /// Rows the grid is shifted up (``rowShift(keeping:from:)``).
        public var shift: Int
        /// The grid's first rows drawn over the top of the area (0: none).
        public var headerRows: Int

        public init(shift: Int, headerRows: Int) {
            self.shift = shift
            self.headerRows = headerRows
        }
    }

    /// The top exception for a Mac grid taller than the phone's area (Leo,
    /// 2026-11-23: "at the bottom of the terminal when im there the header of
    /// the claude code thing disappears ... when im not at the bottom it's
    /// fine"). Following the cursor to the bottom shifts the grid's top off
    /// the area; its first `headerRows` rows (Claude Code's and Codex's
    /// header box, htop's meters) then stay pinned there, as they do while the
    /// keyboard clips the top (`TerminalGridSizing.keyboardPlacement`), over
    /// a body that still keeps the cursor's row in view. No header while the
    /// grid's top shows (no shift) or the cursor is in the header rows.
    /// Capped at a third of the visible rows, as the keyboard's.
    public func rowPlacement(keeping cursorRow: Int?, from current: Int,
                             headerRows: Int = TerminalGridSizing.defaultHeaderRows) -> RowPlacement {
        let plain = rowShift(keeping: cursorRow, from: current)
        guard plain > 0, let hostRows else { return RowPlacement(shift: plain, headerRows: 0) }
        let header = max(0, min(headerRows, visibleRows / 3))
        guard header > 0 else { return RowPlacement(shift: plain, headerRows: 0) }
        var shift = plain
        if let cursorRow {
            // The cursor is in the header rows: the grid's top as it is.
            if cursorRow < header { return RowPlacement(shift: plain, headerRows: 0) }
            // The header covers the body's first rows: keep the cursor under it.
            if cursorRow < shift + header { shift = cursorRow - header }
        }
        shift = min(max(0, shift), hostRows - visibleRows)
        return RowPlacement(shift: shift, headerRows: shift > 0 ? header : 0)
    }

    /// Whether the Mac's grid differs from what the phone would show (the note shows).
    public var differsFromPhone: Bool {
        guard let hostColumns, let hostRows else { return false }
        return isCapped || hostColumns != ownColumns || hostRows != visibleRows
    }

    /// The primary screen's bottom inset that pins a shorter grid to the
    /// top of a page `pageHeight` tall whose rows start at `top`: the grid's
    /// last row ends above the letterbox (nil: no letterbox, the last row
    /// rests on the composer as usual).
    public func pinnedBottomInset(pageHeight: CGFloat, top: CGFloat) -> CGFloat? {
        guard let box = letterbox else { return nil }
        return max(0, pageHeight - top - box.top)
    }

    /// The note's compact form, for a grid that fills the page (no
    /// letterbox): `120×40`, plus `· 12 cols hidden` when the phone shows
    /// only the first ``columns`` (docs/shared-terminal-sizing.md
    /// "Showing the bounds"). Nil when the grid is the phone's.
    public var compactNote: String? {
        guard differsFromPhone, let hostColumns, let hostRows else { return nil }
        let size = "\(hostColumns)×\(hostRows)"
        return isCapped ? "\(size) · \(hostColumns - columns) cols hidden" : size
    }

    /// The one-line note in the letterbox: `120×40 · set by Aziz's Mac`.
    /// `owner` is the device that set the grid, when the size state names it.
    /// Without one the note gives the size alone: it never claims another
    /// device it cannot name (Leo, 2026-11-15, on "39x26 set by another
    /// device": "its not accurtae").
    public func note(owner: String?) -> String? {
        guard differsFromPhone, let hostColumns, let hostRows else { return nil }
        let size = isCapped
            ? "\(hostColumns)×\(hostRows), too wide for this iPhone (\(columns) columns shown)"
            : "\(hostColumns)×\(hostRows)"
        guard let owner, !owner.isEmpty else { return size }
        return "\(size) · set by \(owner)"
    }
}
