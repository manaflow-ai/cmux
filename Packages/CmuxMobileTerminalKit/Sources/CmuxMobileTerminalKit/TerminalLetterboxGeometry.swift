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
