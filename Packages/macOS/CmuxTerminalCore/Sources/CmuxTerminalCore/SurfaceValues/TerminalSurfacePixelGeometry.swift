import Foundation
public import CoreGraphics

/// Pure pixel/scale derivation for the AppKit terminal surface resize cold path.
///
/// Computes the backing-pixel size, per-axis scale, layer contents scale, and
/// Metal drawable pixel size from a resolved point size and the window backing
/// scale. It holds no AppKit object and touches no `CALayer`, so it lives here
/// as a `Sendable` value; the `GhosttyNSView` witness keeps every
/// `CATransaction`/`CAMetalLayer` mutation, `terminalSurface.updateSize` call,
/// and DEBUG logging app-side and reads the derived geometry from this computer.
public struct TerminalSurfacePixelGeometry: Sendable, Equatable {
    /// The backing-pixel size: the point size times the clamped backing scale.
    public let backingSize: CGSize
    /// The horizontal backing-to-point scale.
    public let xScale: CGFloat
    /// The vertical backing-to-point scale.
    public let yScale: CGFloat
    /// The layer `contentsScale`: the backing scale clamped to at least `1`.
    public let layerScale: CGFloat
    /// The Metal drawable pixel size: the floored, non-negative backing size.
    public let drawablePixelSize: CGSize
    /// Whether the backing size is positive on both axes.
    public let isValid: Bool

    /// Derives the pixel geometry from a resolved point size and backing scale.
    ///
    /// Mirrors the surface-resize derivation: the backing scale is clamped to at
    /// least `1` before multiplying, so ancestor magnification (canvas zoom)
    /// never re-typesets the grid at a shrunken pixel grid. In split mode the
    /// backing-scale and convert-to-backing formulas are identical.
    public init(resolvedSize size: CGSize, backingScale: CGFloat) {
        let backingSize = CGSize(
            width: size.width * max(1.0, backingScale),
            height: size.height * max(1.0, backingScale)
        )
        self.backingSize = backingSize
        self.isValid = backingSize.width > 0 && backingSize.height > 0
        self.xScale = backingSize.width / size.width
        self.yScale = backingSize.height / size.height
        self.layerScale = max(1.0, backingScale)
        self.drawablePixelSize = CGSize(
            width: floor(max(0, backingSize.width)),
            height: floor(max(0, backingSize.height))
        )
    }

    /// Resolves the effective surface point size from the preferred size, the
    /// current view bounds, and the pending size, in that fallback order.
    ///
    /// Returns the first candidate that is positive on both axes; if none
    /// qualifies it returns the current bounds, matching the legacy fallback.
    public static func resolvedSurfaceSize(
        preferred size: CGSize?,
        currentBounds: CGSize,
        pending: CGSize?
    ) -> CGSize {
        if let size,
           size.width > 0,
           size.height > 0 {
            return size
        }
        if currentBounds.width > 0, currentBounds.height > 0 {
            return currentBounds
        }
        if let pending,
           pending.width > 0,
           pending.height > 0 {
            return pending
        }
        return currentBounds
    }
}
