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
///   enough to keep the cursor row on screen (`rowShift(keeping:from:)`).
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

    /// Widest surface Ghostty's layer draws (as `TerminalMirrorRows`: 8192 px).
    static let maxSurfacePixels: CGFloat = 8192
    /// Cells kept between the cursor and the edge it pans toward.
    static let cursorMargin = 4

    public init(viewportWidth: CGFloat, cell: CGSize, scale: CGFloat, hostColumns: Int?, hostRows: Int?, visibleRows: Int) {
        self.viewportWidth = viewportWidth
        self.cell = cell
        self.scale = scale
        self.hostColumns = hostColumns
        self.hostRows = hostRows
        self.visibleRows = visibleRows
    }

    /// Columns the page fits at the phone's font size.
    public var phoneColumns: Int {
        cell.width > 0 ? max(1, Int(floor(viewportWidth / cell.width))) : 0
    }

    /// The mirror's columns: the Mac's (capped to the widest surface), else the phone's.
    public var columns: Int {
        guard let hostColumns, hostColumns > 0, cell.width > 0 else { return phoneColumns }
        let widest = Int(floor(Self.maxSurfacePixels / (cell.width * max(1, scale))))
        return min(hostColumns, max(1, widest))
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
    /// pixel rounding. The phone's own grid keeps the page's width.
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

    /// Whether the Mac's grid differs from what the phone would show (the note shows).
    public var differsFromPhone: Bool {
        guard let hostColumns, let hostRows else { return false }
        return isCapped || hostColumns != phoneColumns || hostRows != visibleRows
    }

    /// The one-line note in the letterbox: `120×40 · set by Aziz's Mac`.
    /// `owner` is the device that set the grid, when the size state names it.
    public func note(owner: String?) -> String? {
        guard differsFromPhone, let hostColumns, let hostRows else { return nil }
        let size = isCapped
            ? "\(hostColumns)×\(hostRows), too wide for this iPhone (\(columns) columns shown)"
            : "\(hostColumns)×\(hostRows)"
        guard let owner, !owner.isEmpty else { return "\(size) · set by another device" }
        return "\(size) · set by \(owner)"
    }
}

/// Where a full-screen app's grid sits vertically in the TUI area, for the
/// layout pass the keyboard animates (user report 2026-11-12, "the resizing
/// is so wack": a letterboxed grid slid down with the hiding keyboard, then
/// jumped back to the top once the keyboard settled).
///
/// - The phone's own grid (the Mac's rows are the rows the phone claims, or
///   there is no Mac grid) rides the composer (design/terminal R1-1): its
///   bottom row stays on the composer and the top is clipped while the
///   keyboard is up, until the one resize at the settle.
/// - A grid whose rows another device set does not resize with the
///   keyboard, so it is pinned to the top of the TUI area with the keyboard
///   up and down alike. Its letterbox and row shift follow the rows on
///   screen in this pass (`visibleRows`), not the rows claimed at the last
///   settle, so the keyboard's own layout pass places it once, at its end
///   placement.
///
/// Pure geometry in the view's coordinates; the controller applies it.
public struct TerminalTUIPlacement: Equatable, Sendable {
    public var cellHeight: CGFloat
    /// The Mac's rows (nil: the phone's own grid, a local session).
    public var hostRows: Int?
    /// The rows the phone claims (`TerminalTUISizing`), changed only when the keyboard settles.
    public var phoneRows: Int
    /// The top of the TUI area (under the toolbar or the status bar).
    public var chromeTop: CGFloat
    /// The composer stack's top in this layout pass (the TUI area's bottom).
    public var stackTop: CGFloat

    public init(cellHeight: CGFloat, hostRows: Int?, phoneRows: Int, chromeTop: CGFloat, stackTop: CGFloat) {
        self.cellHeight = cellHeight
        self.hostRows = hostRows
        self.phoneRows = phoneRows
        self.chromeTop = chromeTop
        self.stackTop = stackTop
    }

    /// Whether the grid is the phone's own and rides the composer.
    public var ridesComposer: Bool {
        guard let hostRows, hostRows > 0, cellHeight > 0 else { return true }
        return hostRows == phoneRows
    }

    /// The rows the grid shows in this pass: the claimed rows for the
    /// phone's own grid, the rows that fit above the composer for another
    /// device's (for `TerminalHostGridLayout.visibleRows`).
    public var visibleRows: Int {
        guard !ridesComposer else { return phoneRows }
        return max(1, Int(floor((stackTop - chromeTop) / cellHeight)))
    }

    /// The grid host's top in the view (before the row shift).
    public var hostTop: CGFloat {
        ridesComposer ? stackTop - CGFloat(phoneRows) * cellHeight : chromeTop
    }
}
