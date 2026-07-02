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

    /// The bottom occupancy implied by a SAMPLED keyboard-layout-guide top edge,
    /// in the host view's coordinate space.
    ///
    /// This is the live counterpart of ``keyboardOccupancy(keyboardHeight:bottomSafeAreaInset:)``:
    /// `UIKeyboardLayoutGuide`'s top edge rests on the bottom safe-area edge while
    /// the keyboard is down and rides the keyboard's real animated top while it
    /// moves, so `bounds.height - guideTop` IS the current bottom occupancy at any
    /// instant of the system keyboard animation (including interactive dismiss).
    /// Sampling the guide-pinned anchor's presentation layer and feeding this
    /// value into the dock/viewport math is what keeps the terminal edge glued to
    /// the keyboard, instead of replaying the notification's duration/curve and
    /// hoping it matches UIKit's private spring.
    ///
    /// Clamped to `[0, boundsHeight]` so a transient out-of-bounds sample (mid
    /// rotation, detached guide) cannot produce a negative or over-full
    /// reservation.
    ///
    /// - Parameters:
    ///   - keyboardGuideTopY: The sampled guide top edge (min-Y) in view points.
    ///   - boundsHeight: The host view bounds height in points.
    /// - Returns: The live bottom occupancy in points.
    public static func sampledBottomOccupancy(
        keyboardGuideTopY: CGFloat,
        boundsHeight: CGFloat
    ) -> CGFloat {
        guard boundsHeight > 0 else { return 0 }
        return min(max(0, boundsHeight - keyboardGuideTopY), boundsHeight)
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
