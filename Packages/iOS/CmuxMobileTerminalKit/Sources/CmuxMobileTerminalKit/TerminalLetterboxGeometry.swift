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

    /// The drawable container size after subtracting the keyboard overlap.
    ///
    /// Mirrors the legacy `containerW`/`containerH`/`bottomInset` computation:
    /// the bottom inset is clamped to `[0, height - 1]`, the width floored at 1
    /// point and the height at 1 point after removing the inset.
    ///
    /// - Parameters:
    ///   - bounds: The host view bounds size in points.
    ///   - keyboardHeight: The keyboard overlap in points.
    /// - Returns: The drawable container size in points.
    public static func drawableContainerSize(bounds: CGSize, keyboardHeight: CGFloat) -> CGSize {
        let bottomInset = min(max(0, keyboardHeight), max(0, bounds.height - 1))
        let containerW = max(1, bounds.width)
        let containerH = max(1, bounds.height - bottomInset)
        return CGSize(width: containerW, height: containerH)
    }

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

    /// The terminal grid container size after reserving the whole bottom dock
    /// (keyboard / safe area + composer band + persistent toolbar), in points.
    ///
    /// This is the host-testable form of `syncSurfaceGeometry`'s `reservedBottom`
    /// + `containerH` math. It locks in the keyboard open/closed contract:
    ///
    /// - Keyboard DOWN (`keyboardHeight == 0`), chrome visible: the grid is the
    ///   full bounds height minus the bottom safe area, the composer band, and
    ///   the toolbar. With no composer/toolbar that is `bounds.height -
    ///   bottomSafeAreaInset`.
    /// - Keyboard UP (`keyboardHeight > 0`): the grid additionally loses the
    ///   keyboard height (the safe-area fallback is NOT also subtracted; the
    ///   keyboard already covers the home indicator).
    /// - Chrome hidden (HIDE button): only an actual keyboard is reserved; the
    ///   grid reclaims the toolbar, composer band, AND the bottom safe area.
    ///
    /// Because the keyboard-down height is derived purely from the CURRENT
    /// `keyboardHeight` (0) and the passed safe-area inset, it cannot depend on a
    /// stale prior keyboard value: once `keyboardHeight` returns to 0 the height
    /// returns to full (minus only the steady-state chrome).
    ///
    /// - Parameters:
    ///   - bounds: The host view bounds size in points.
    ///   - keyboardHeight: The keyboard overlap in points (0 when down).
    ///   - composerBandHeight: The open composer band height in points (0 closed).
    ///   - toolbarHeight: The reserved persistent toolbar height in points.
    ///   - bottomSafeAreaInset: The resolved bottom safe-area inset in points.
    ///   - chromeHidden: True while the HIDE button has suppressed the dock.
    /// - Returns: The grid container size in points.
    public static func terminalContainerSize(
        bounds: CGSize,
        keyboardHeight: CGFloat,
        composerBandHeight: CGFloat,
        toolbarHeight: CGFloat,
        bottomSafeAreaInset: CGFloat,
        chromeHidden: Bool
    ) -> CGSize {
        let reservedBottom: CGFloat
        if chromeHidden {
            reservedBottom = max(0, keyboardHeight)
        } else {
            let occupancy = keyboardOccupancy(
                keyboardHeight: keyboardHeight,
                bottomSafeAreaInset: bottomSafeAreaInset
            )
            reservedBottom = max(0, composerBandHeight) + max(0, toolbarHeight) + occupancy
        }
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

    /// The bottom edge (max Y) the render rect should pin to inside the
    /// viewport, given the LIVE viewport bottom (the toolbar's presentation
    /// position mid keyboard animation) and the TARGET layout viewport bottom
    /// (where the animation will settle).
    ///
    /// The render is bottom-pinned to the live viewport so a letterboxed box
    /// and the prompt line ride the keyboard edge. But during a keyboard
    /// DISMISSAL the surface is already sized for the (taller) target
    /// viewport while the live viewport is still keyboard-small; pinning the
    /// tall render to the small live bottom shoves the top rows off screen by
    /// `renderHeight - liveHeight` and they slide back down as the keyboard
    /// leaves (the "content pushed up, then settles" glitch). Content that is
    /// visible at settle must never be clipped mid-flight, so the bottom edge
    /// is allowed to extend past the live viewport (under the keyboard) up to
    /// the point where the render's top reaches the viewport top — but never
    /// past the target bottom, so a small letterboxed box still rides the
    /// live edge instead of jumping behind the keyboard.
    ///
    /// - `renderHeight <= live`: pins to the live bottom (unchanged).
    /// - `renderHeight > live` during growth: pins to
    ///   `min(target, viewportMinY + renderHeight)` — the top stays put and
    ///   lower rows are revealed as the keyboard departs.
    /// - Steady state (`live == target`): identical to the legacy behavior.
    ///
    /// `holdsProvisionalPin` marks a render whose size still reflects an
    /// UNSETTLED grid negotiation (keyboard transition in flight, or the
    /// capacity report's round-trip has not confirmed). While the viewport
    /// grows under a provisional pin, the render holds its top edge instead
    /// of riding the live bottom: the granted grid is one round-trip from
    /// being superseded, and riding the departing keyboard slid the squeezed
    /// content to the bottom only for the fresh grant to snap it back to the
    /// top (the "content bounces down then up on keyboard close" glitch).
    /// A settled letterboxed box (a genuinely smaller device pins the shared
    /// grid) keeps the legacy ride so it stays glued to the dock.
    ///
    /// While the viewport SHRINKS under a provisional pin (keyboard rising,
    /// old render still applied), the render slides up only as much as
    /// needed to keep the cursor row visible above the keyboard, instead of
    /// riding the screen bottom. The rows the keyboard covers are usually
    /// the BLANK rows below the prompt, so pinning the screen bottom to the
    /// keyboard edge shoved every content row up by the keyboard height and
    /// the settle resize dropped them back — the "all rows momentarily
    /// pushed up" glitch. `cursorBottomInRender` is the cursor's bottom
    /// edge in render-local points; when it is unknown the legacy
    /// screen-bottom ride is kept (never hides the prompt).
    ///
    /// - Parameters:
    ///   - liveViewportMaxY: The live viewport bottom edge in points.
    ///   - targetViewportMaxY: The target (layout) viewport bottom edge.
    ///   - viewportMinY: The viewport top edge in points.
    ///   - renderHeight: The render rect height in points.
    ///   - holdsProvisionalPin: True while the grid negotiation is unsettled.
    ///   - cursorBottomInRender: The cursor bottom in render-local points,
    ///     when known.
    /// - Returns: The bottom edge to pin the render rect to.
    public static func renderPinnedBottomEdge(
        liveViewportMaxY: CGFloat,
        targetViewportMaxY: CGFloat,
        viewportMinY: CGFloat,
        renderHeight: CGFloat,
        holdsProvisionalPin: Bool = false,
        cursorBottomInRender: CGFloat? = nil
    ) -> CGFloat {
        if holdsProvisionalPin, liveViewportMaxY < targetViewportMaxY {
            return min(targetViewportMaxY, viewportMinY + renderHeight)
        }
        // `>=` so the anchor keeps holding after the keyboard lands (live ==
        // target) while the deferred resize is still waiting on the grid
        // negotiation — releasing at equality would shove the rows up for
        // the final stretch of the transition.
        if holdsProvisionalPin,
           liveViewportMaxY >= targetViewportMaxY,
           let cursorBottom = cursorBottomInRender,
           cursorBottom > 0 {
            // Blank space below the cursor absorbs the keyboard intrusion
            // before any content moves; once the cursor row itself would be
            // covered, the render rides the live edge exactly like before.
            let blankBelowCursor = max(0, renderHeight - cursorBottom)
            return min(viewportMinY + renderHeight, liveViewportMaxY + blankBelowCursor)
        }
        return max(liveViewportMaxY, min(targetViewportMaxY, viewportMinY + renderHeight))
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
