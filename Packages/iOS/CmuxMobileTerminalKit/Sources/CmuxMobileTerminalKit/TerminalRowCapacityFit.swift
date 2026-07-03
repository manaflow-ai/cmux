public import CoreGraphics
import Foundation

/// Pure math for the "stretch to fill" font fit: when another attached device
/// constrains the shared PTY to fewer rows than this device can show at the
/// user's base font, the surface raises its RENDERED font just enough that
/// the granted rows fill the viewport, instead of parking a dead letterbox
/// band above the content.
///
/// A value carries one geometry measurement (container height, measured cell
/// height, and the font that produced that cell). The negotiation stays
/// self-healing because the two directions are decoupled:
///
/// - **Reported rows** are always the row CAPACITY at the user's BASE font
///   (``capacityRows(atBaseFontSize:)``). The report does not depend on the
///   fitted font, so the daemon's min-per-axis grid can rise back up the
///   moment the constraining device grows — a report derived from the fitted
///   font would make the negotiated minimum a one-way ratchet the phone could
///   never escape.
/// - **Rendered rows** track the effective grid:
///   ``fitFontSize(forEffectiveRows:)`` picks the font whose cell height
///   makes exactly the granted rows fill the container, and the columns
///   re-report at that rendered font (columns must never exceed what the
///   rendered font can actually show).
public struct TerminalRowCapacityFit {
    /// Rows past which a mismatch between the rendered grid and the effective
    /// grid triggers a re-fit. One row of slack is inherent to cell flooring;
    /// two rows means a visible band (or clipping) worth a font adjustment.
    public static let refitThresholdRows = 2

    /// The grid container height in device pixels.
    public let containerPixelHeight: CGFloat
    /// The measured cell height in device pixels at ``liveFontSize``.
    public let cellPixelHeight: CGFloat
    /// The font currently rendering (the one the cell was measured at).
    public let liveFontSize: Float32

    /// Creates a fit over one geometry measurement, or nil when any input is
    /// not measurable yet (pre-layout zeroes).
    public init?(containerPixelHeight: CGFloat, cellPixelHeight: CGFloat, liveFontSize: Float32) {
        guard containerPixelHeight > 0, cellPixelHeight > 0, liveFontSize > 0 else { return nil }
        self.containerPixelHeight = containerPixelHeight
        self.cellPixelHeight = cellPixelHeight
        self.liveFontSize = liveFontSize
    }

    /// Whether the rendered grid is far enough from the effective grid to be
    /// worth a font adjustment (hysteresis so sub-cell flooring noise and
    /// one-row mismatches never oscillate the font).
    public static func shouldRefit(renderedRows: Int, effectiveRows: Int) -> Bool {
        guard renderedRows > 0, effectiveRows > 0 else { return false }
        return abs(renderedRows - effectiveRows) >= refitThresholdRows
    }

    /// The row capacity this device should REPORT: how many rows fit in the
    /// container at the user's base font. Cell height scales linearly with
    /// the font point size, so the base-font cell height is derived from the
    /// measured live cell without a second libghostty round trip.
    public func capacityRows(atBaseFontSize baseFontSize: Float32) -> Int? {
        guard baseFontSize > 0 else { return nil }
        let baseCellHeight = cellPixelHeight * CGFloat(baseFontSize) / CGFloat(liveFontSize)
        guard baseCellHeight > 0 else { return nil }
        return max(1, Int((containerPixelHeight / baseCellHeight).rounded(.down)))
    }

    /// The font size at which exactly `effectiveRows` rows fill the container.
    ///
    /// Solves `floor(containerPx / cellPx(font)) == effectiveRows` using the
    /// linear cell-height model, aiming a quarter-row PAST the target so the
    /// floor lands on `effectiveRows` rather than one short of it (a hair of
    /// overshoot would otherwise drop the capacity below the granted grid and
    /// shrink the shared PTY for every attached device).
    public func fitFontSize(forEffectiveRows effectiveRows: Int) -> Float32? {
        guard effectiveRows > 0 else { return nil }
        let targetCellHeight = containerPixelHeight / (CGFloat(effectiveRows) + 0.25)
        let ratio = targetCellHeight / cellPixelHeight
        return liveFontSize * Float32(ratio)
    }
}
