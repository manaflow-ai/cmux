import CoreGraphics
import Foundation
import IOSurface

/// A surface's cursor cell as Ghostty publishes it with an external cursor (ghostty-next p03-rendering-090,
/// `ghostty_cursor_cell_s`, `GHOSTTY_EXTERNAL_CURSOR` in Package.swift): once per move or change of the cell,
/// in the Core Animation transaction that presents the frame the cell was drawn for.
/// ``TerminalCursorPresenter`` shows it; Ghostty then neither draws nor blinks the cursor, so a blink costs it no
/// frame.
nonisolated struct TerminalCursorState: Sendable, Equatable {
    /// The cursor's shape, as Ghostty's renderer picks it (`renderer/cursor.zig`, `style`): a hollow block
    /// while the surface is unfocused, a block over IME preedit text, a lock at a password prompt.
    nonisolated enum Style: Sendable, Equatable {
        case block, blockHollow, bar, underline, lock
    }

    /// The cursor cell's pixels, glyph included, as Ghostty draws them (`surface` of `ghostty_cursor_cell_s`).
    /// Each published cell has a new surface: Ghostty never draws into one after publishing it. The SDK
    /// declares `IOSurface` Sendable (its retain, release and use as layer contents are thread-safe), and this
    /// immutable value only carries the reference from Ghostty's presenting thread to the cursor layer.
    nonisolated struct Image: Sendable, Equatable {
        let surface: IOSurface

        static func == (lhs: Image, rhs: Image) -> Bool { lhs.surface === rhs.surface }
    }

    /// What the main thread needs of a cell to run its blink (``TerminalCursorLayer``), in one word so the
    /// presenting thread can leave the newest for main without a lock (``TerminalCursorPresenter``).
    nonisolated struct Blink: Sendable, Equatable {
        /// The cell shows: visible, with pixels.
        var shows: Bool
        /// The cursor blinks: the program or `cursor-style-blink` asks for it and the surface has focus.
        var blinking: Bool
        /// Milliseconds the cursor shows, then hides, in one blink.
        var intervalMS: UInt32

        init(shows: Bool, blinking: Bool, intervalMS: UInt32) {
            self.shows = shows
            self.blinking = blinking
            self.intervalMS = intervalMS
        }

        init(word: UInt64) {
            shows = word & 1 != 0
            blinking = word & 2 != 0
            intervalMS = UInt32(truncatingIfNeeded: word >> 32)
        }

        var word: UInt64 { (shows ? 1 : 0) | (blinking ? 2 : 0) | UInt64(intervalMS) << 32 }

        /// Whether a blink loop runs for this cell.
        var wantsLoop: Bool { shows && blinking }

        /// Seconds the cursor shows, then hides; Ghostty's own when the cell names none.
        var interval: TimeInterval {
            intervalMS > 0 ? TimeInterval(intervalMS) / 1000 : TerminalCursorState.defaultBlinkInterval
        }
    }

    /// Ghostty's own blink half-period (`blink_interval_ms`, ghostty-next `src/renderer/cursor.zig`), for a
    /// cell that names none.
    static let defaultBlinkInterval: TimeInterval = 0.6

    /// Increases with each cell Ghostty publishes for a surface.
    var serial: UInt64 = 0
    /// The cursor cell (two cells for a wide character) in the surface's pixels, from the top-left corner of its
    /// frames.
    var cell: CGRect
    var style: Style
    /// False while the program hides the cursor (DECTCEM), it is scrolled out of the viewport, or the frames draw
    /// it (IME preedit, a custom shader).
    var visible: Bool
    var blinking: Bool
    /// Milliseconds the cursor shows, then hides, in one blink; 0 for a steady cursor.
    var blinkIntervalMS: UInt32 = 0
    var image: Image?

    var blink: Blink { Blink(shows: visible && image != nil, blinking: blinking, intervalMS: blinkIntervalMS) }

    /// ``cell`` in points of a flipped layer the size of the surface's view: Ghostty's layer shows its frame from
    /// the top-left corner (`contentsGravity`), so the cell keeps its distance from the top at any view height.
    func frame(scale: CGFloat) -> CGRect {
        let scale = scale > 0 ? scale : 1
        return CGRect(x: cell.minX / scale, y: cell.minY / scale, width: cell.width / scale, height: cell.height / scale)
    }
}
