public import CoreGraphics
import Foundation

/// Pure letterbox-fit math for the terminal surface.
///
/// Absorbs the pixel arithmetic previously inlined in the iOS surface view's
/// `syncSurfaceGeometry` and `fitSurfaceToGrid` (the parts that do not call
/// libghostty): the container pixel size, the request box for an effective
/// grid pin, and the decision of whether to letterbox and at what point size.
/// The arithmetic is byte-for-byte identical to the legacy path so the surface
/// converges on the exact same grid; this layer just makes it testable.
public struct TerminalLetterboxGeometry {
    private init() {}

    /// The bottom occupancy reserved for the keyboard (when up) or the bottom
    /// safe area (when the keyboard is down so the always-visible toolbar clears
    /// the home indicator).
    ///
    /// Mirrors `GhosttySurfaceView.keyboardOccupancyInBounds`: the live keyboard
    /// height takes priority, and only falls back to the safe-area inset when the
    /// keyboard is fully down. Both inputs are clamped to be non-negative so a
    /// transient negative inset cannot grow the reservation.
    ///
    /// - Parameters:
    ///   - keyboardHeight: The keyboard overlap in points (0 when down).
    ///   - bottomSafeAreaInset: The resolved bottom safe-area inset in points.
    /// - Returns: The bottom occupancy in points.
    public static func keyboardOccupancy(keyboardHeight: CGFloat, bottomSafeAreaInset: CGFloat) -> CGFloat {
        keyboardHeight > 0 ? max(0, keyboardHeight) : max(0, bottomSafeAreaInset)
    }

    /// The vertical seam kept between the rendered terminal's bottom edge and
    /// the dock (composer bar) top while the bottom chrome is visible, in
    /// points. Without it the last row of content sits flush against the
    /// toolbar pills, which reads as crowding. Reserved inside the grid
    /// container — never applied as a render offset — so the render still
    /// rides the dock through the host's unchanged constraint system and
    /// nothing clips; the render's bottom edge simply lands this many points
    /// above the dock top.
    public static let dockSeamPadding: CGFloat = 8

    /// The terminal grid container size after reserving the steady-state bottom
    /// chrome (bottom safe area + composer band + persistent toolbar) plus the
    /// dock seam, in points.
    ///
    /// The keyboard is deliberately NOT an input. The grid keeps its
    /// keyboard-down size while the keyboard is up; the render is translated so
    /// its bottom edge rides the dock (composer bar) and the top rows clip
    /// behind the screen top. A keyboard toggle therefore never renegotiates
    /// the shared PTY grid, so there is no resize round-trip to mask: the old
    /// "content pushed down, then resized to full" dismissal glitch cannot
    /// occur, and the Mac-side terminal stops reflowing every time the phone's
    /// keyboard toggles.
    ///
    /// - Chrome visible: the grid is the full bounds height minus the bottom
    ///   safe area, the composer band, the toolbar, and `dockSeamPadding`.
    /// - Chrome hidden (HIDE button): the grid reclaims everything; nothing is
    ///   reserved (there is no bar to keep a seam against).
    ///
    /// - Parameters:
    ///   - bounds: The host view bounds size in points.
    ///   - composerBandHeight: The open composer band height in points (0 closed).
    ///   - toolbarHeight: The reserved persistent toolbar height in points.
    ///   - bottomSafeAreaInset: The resolved bottom safe-area inset in points.
    ///   - chromeHidden: True while the HIDE button has suppressed the dock.
    /// - Returns: The grid container size in points.
    public static func terminalContainerSize(
        bounds: CGSize,
        composerBandHeight: CGFloat,
        toolbarHeight: CGFloat,
        bottomSafeAreaInset: CGFloat,
        chromeHidden: Bool
    ) -> CGSize {
        let reservedBottom: CGFloat = chromeHidden
            ? 0
            : max(0, composerBandHeight) + max(0, toolbarHeight) + max(0, bottomSafeAreaInset)
                + dockSeamPadding
        let bottomInset = min(reservedBottom, max(0, bounds.height - 1))
        let containerW = max(1, bounds.width)
        let containerH = max(1, bounds.height - bottomInset)
        return CGSize(width: containerW, height: containerH)
    }

    /// Resolve the bottom safe-area inset, preferring the view's own inset and
    /// falling back to the window's when the view inset is zero (it can be zero
    /// before the view is on a window, and STALE for one layout pass right after
    /// the keyboard hides).
    ///
    /// Mirrors `GhosttySurfaceView.safeAreaInsetsBottom`. Factored out so the
    /// "do not trust a zero view inset" rule is host-testable: passing a zero
    /// (stale) view inset must return the window inset, not zero, so the
    /// keyboard-down grid height does not briefly over-extend under the home
    /// indicator and then snap back.
    ///
    /// - Parameters:
    ///   - viewInset: The view's `safeAreaInsets.bottom` (may be a stale 0).
    ///   - windowInset: The window's `safeAreaInsets.bottom` (authoritative).
    /// - Returns: The inset to reserve in points.
    public static func resolvedBottomSafeAreaInset(viewInset: CGFloat, windowInset: CGFloat) -> CGFloat {
        viewInset > 0 ? viewInset : max(0, windowInset)
    }

    /// The container size in device pixels for libghostty's `set_size`.
    ///
    /// Floors `container * scale` and clamps each axis to at least 1 pixel,
    /// matching the legacy `containerPxW`/`containerPxH`.
    ///
    /// - Parameters:
    ///   - container: The drawable container size in points.
    ///   - scale: The screen scale factor.
    /// - Returns: The pixel size as `(width, height)`.
    public static func containerPixelSize(container: CGSize, scale: CGFloat) -> (width: UInt32, height: UInt32) {
        let w = UInt32(max(1, Int((container.width * scale).rounded(.down))))
        let h = UInt32(max(1, Int((container.height * scale).rounded(.down))))
        return (w, h)
    }

    /// The initial requested pixel box to fit a `cols × rows` grid.
    ///
    /// Floors `cols * cellWidth` / `rows * cellHeight` and clamps to at least 1
    /// pixel each, matching the start of the legacy `fitSurfaceToGrid` before
    /// its libghostty refinement loop.
    ///
    /// - Parameters:
    ///   - cols: The target column count.
    ///   - rows: The target row count.
    ///   - cellPixelSize: The measured cell size in device pixels.
    /// - Returns: The requested pixel box as `(width, height)`.
    public static func gridRequestPixelSize(cols: Int, rows: Int, cellPixelSize: CGSize) -> (width: UInt32, height: UInt32) {
        let w = UInt32(max(1, Int((CGFloat(cols) * cellPixelSize.width).rounded(.down))))
        let h = UInt32(max(1, Int((CGFloat(rows) * cellPixelSize.height).rounded(.down))))
        return (w, h)
    }

    /// Whether the surface should be letterbox-pinned to `effective` inside the
    /// container, and the candidate pinned point size when it should.
    ///
    /// Reproduces the legacy guard exactly: skip pinning when the effective grid
    /// already fills (or is within one cell of) the measured natural grid, or
    /// when the pinned box would not be meaningfully smaller than the container
    /// (the `+ 0.5` point tolerance on either axis).
    ///
    /// - Parameters:
    ///   - effective: The daemon-authoritative `(cols, rows)` grid.
    ///   - measuredColumns: The surface's measured natural columns.
    ///   - measuredRows: The surface's measured natural rows.
    ///   - cell: The measured cell size in device pixels.
    ///   - scale: The screen scale factor.
    ///   - container: The drawable container size in points.
    /// - Returns: `nil` when the surface should fill the container, otherwise
    ///   the candidate pinned size in points (pre-libghostty-refinement).
    public static func pinnedPointSize(
        effective: (cols: Int, rows: Int),
        measuredColumns: Int,
        measuredRows: Int,
        cell: CGSize,
        scale: CGFloat,
        container: CGSize
    ) -> CGSize? {
        guard effective.cols > 0, effective.rows > 0, cell.width > 0, cell.height > 0 else { return nil }
        let fillsNaturalGrid = effective.cols >= measuredColumns && effective.rows >= measuredRows
        let withinOneCell = (measuredColumns - effective.cols) <= 1 && (measuredRows - effective.rows) <= 1
        let pinnedW = CGFloat(effective.cols) * cell.width / scale
        let pinnedH = CGFloat(effective.rows) * cell.height / scale
        guard !fillsNaturalGrid, !withinOneCell,
              pinnedW + 0.5 < container.width || pinnedH + 0.5 < container.height else {
            return nil
        }
        return CGSize(width: pinnedW, height: pinnedH)
    }

    /// Clamps a libghostty-refined pixel box back into point space, bounded by
    /// the container.
    ///
    /// Matches the legacy final `pinnedSize` assignment:
    /// `min(actualPx / scale, containerPoints)` per axis.
    ///
    /// - Parameters:
    ///   - actualWidthPx: The refined pixel width from libghostty.
    ///   - actualHeightPx: The refined pixel height from libghostty.
    ///   - scale: The screen scale factor.
    ///   - container: The drawable container size in points.
    /// - Returns: The final pinned point size.
    public static func clampPinnedSize(
        actualWidthPx: CGFloat,
        actualHeightPx: CGFloat,
        scale: CGFloat,
        container: CGSize
    ) -> CGSize {
        CGSize(
            width: min(actualWidthPx / scale, container.width),
            height: min(actualHeightPx / scale, container.height)
        )
    }

    /// How much of the keyboard intrusion the BLANK space below the terminal
    /// content absorbs before the render slides at all.
    ///
    /// While the content bottom fits above the composer bar the terminal
    /// stays top-pinned (the keyboard covers only blank rows); once content
    /// outgrows the visible window the slack shrinks row by row and the
    /// render transitions smoothly into the full bottom-pin, where the newest
    /// rows ride the composer bar. `nil` blank (cursor unknown, or an
    /// alternate-screen app that owns the whole grid) absorbs nothing: the
    /// safe default is the plain bottom-pin.
    ///
    /// - Parameters:
    ///   - blankBelowContent: Points of blank render below the content bottom,
    ///     or `nil` when it cannot be trusted.
    ///   - intrusion: How far the dock top sits above its keyboard-down seat.
    /// - Returns: The slack in points, in `[0, intrusion]`.
    public static func keyboardAbsorptionSlack(
        blankBelowContent: CGFloat?,
        intrusion: CGFloat
    ) -> CGFloat {
        guard let blankBelowContent else { return 0 }
        return min(max(0, blankBelowContent), max(0, intrusion))
    }

    /// Resolves one local pixel-scroll delta across the combined scroll axis:
    /// the scrollback position plus the keyboard TOP-REVEAL zone past
    /// scrollback-top.
    ///
    /// While the keyboard is up the bottom-pinned full-height render clips its
    /// top `maxRevealPx` device pixels above the screen, so the oldest
    /// scrollback rows are unreachable by grid scrolling alone: the grid
    /// clamps at position 0 with those rows still hidden. The reveal zone is
    /// the continuation of the same axis: pulling past scrollback-top slides
    /// the render back down (uncovering the clipped top, letting the keyboard
    /// cover the newest rows the user scrolled away from), and scrolling
    /// toward newer content consumes the reveal before the grid moves again,
    /// so the top edge travels continuously through the seam.
    ///
    /// - Parameters:
    ///   - currentPositionPx: The viewport top's distance from scrollback top,
    ///     in device pixels (0 = at scrollback top).
    ///   - currentRevealPx: The reveal already granted, in device pixels.
    ///   - deltaPixels: The gesture delta in device pixels (negative = toward
    ///     older content).
    ///   - maxPositionPx: The bottommost scroll position in device pixels.
    ///   - maxRevealPx: The clipped-top budget in device pixels (0 whenever
    ///     the keyboard is down or the blank band already absorbs the whole
    ///     intrusion); a held reveal beyond the current budget is clamped
    ///     before the delta applies.
    /// - Returns: The next grid position and reveal, in device pixels. At most
    ///   one of the two is nonzero away from its floor: reveal is only ever
    ///   granted at position 0.
    public static func scrollTopRevealResolution(
        currentPositionPx: Double,
        currentRevealPx: Double,
        deltaPixels: Double,
        maxPositionPx: Double,
        maxRevealPx: Double
    ) -> (positionPx: Double, revealPx: Double) {
        let maxPosition = max(0, maxPositionPx)
        let maxReveal = max(0, maxRevealPx)
        // A held reveal is only meaningful against the CURRENT budget: the
        // keyboard dismissing (budget 0) or the blank band growing must not
        // let a stale reveal shift the grid by phantom distance.
        let reveal = maxReveal > 0 ? min(max(0, currentRevealPx), maxReveal) : 0
        // One continuous coordinate: negative territory is the reveal zone,
        // so the seam at scrollback-top needs no ordering special cases —
        // clamping the combined position derives both outputs.
        let combined = min(max(currentPositionPx, 0), maxPosition) - reveal
        let next = min(max(combined + deltaPixels, -maxReveal), maxPosition)
        return (max(0, next), max(0, -next))
    }

    /// The cell size in device pixels derived from a measured surface size.
    ///
    /// Returns `.zero` when any measured dimension is non-positive, matching the
    /// legacy guard before dividing pixel extents by the grid counts.
    ///
    /// - Parameters:
    ///   - columns: Measured columns.
    ///   - rows: Measured rows.
    ///   - widthPx: Measured pixel width.
    ///   - heightPx: Measured pixel height.
    /// - Returns: The per-cell pixel size, or `.zero` when not measurable.
    public static func cellPixelSize(columns: Int, rows: Int, widthPx: Int, heightPx: Int) -> CGSize {
        guard columns > 0, rows > 0, widthPx > 0, heightPx > 0 else { return .zero }
        return CGSize(
            width: CGFloat(widthPx) / CGFloat(columns),
            height: CGFloat(heightPx) / CGFloat(rows)
        )
    }
}
