import CoreGraphics
import Foundation
import IOSurface

/// A surface's cursor as Ghostty publishes it with an external cursor (ghostty-next p03-rendering-090,
/// `GHOSTTY_EXTERNAL_CURSOR` in Package.swift): once per move or change of the cursor cell, on the renderer
/// thread. ``TerminalCursorLayer`` shows it; Ghostty then neither draws nor blinks the cursor, so a blink
/// costs it no frame.
nonisolated struct TerminalCursorState: Sendable, Equatable {
    /// The cursor's shape, as Ghostty's renderer picks it (`renderer/cursor.zig`, `style`): a hollow block
    /// while the surface is unfocused, a block over IME preedit text, a lock at a password prompt.
    nonisolated enum Style: Sendable, Equatable {
        case block, blockHollow, bar, underline, lock
    }

    /// The cursor cell's pixels, glyph included, as Ghostty draws them (`surface` of `ghostty_surface_cursor_s`).
    /// Ghostty does not draw into a published surface again while anyone holds it.
    // crash-allow: an IOSurface is a kernel buffer object whose retain, release and use as layer contents are thread-safe (IOSurface/IOSurfaceRef.h); this immutable value only carries the reference from Ghostty's renderer thread to the main actor and never writes its pixels
    nonisolated struct Image: @unchecked Sendable, Equatable {
        let surface: IOSurface

        static func == (lhs: Image, rhs: Image) -> Bool { lhs.surface === rhs.surface }
    }

    /// Ghostty's own blink half-period (`CURSOR_BLINK_INTERVAL`, ghostty-next `src/renderer/Thread.zig`), for a
    /// publish that names none.
    static let defaultBlinkInterval: TimeInterval = 0.6

    /// The cursor cell in the surface's points, top-left origin (as `ghostty_surface_grid_metrics`).
    var cell: CGRect
    var style: Style
    /// False while the program hides the cursor (DECTCEM) or it is scrolled out of the viewport.
    var visible: Bool
    /// The cursor blinks: the program or `cursor-style-blink` asks for it and the surface has focus.
    var blinking: Bool
    /// Seconds the cursor shows, then hides, in one blink.
    var blinkInterval: TimeInterval = Self.defaultBlinkInterval
    var image: Image?

    /// ``cell`` in AppKit coordinates of a non-flipped view `viewHeight` points tall: Ghostty's layer shows
    /// its frame from the top-left corner (`contentsGravity`), so the cell keeps its distance from the top.
    func layerFrame(viewHeight: CGFloat) -> CGRect {
        CGRect(x: cell.minX, y: viewHeight - cell.maxY, width: cell.width, height: cell.height)
    }
}
