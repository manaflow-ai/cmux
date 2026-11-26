public import CoreGraphics
import Foundation

/// Pure math for the viewport CAPACITY report: how many rows and columns this
/// device can show at the user's BASE font, derived from one geometry
/// measurement (container extent plus the cell size measured at the font that
/// was rendering during that measurement).
///
/// Reported rows and columns are always the capacity at the user's base font
/// (``capacityRows(atBaseFontSize:)`` and ``capacityColumns(atBaseFontSize:)``),
/// never a capacity derived from a transiently different rendered font: a
/// report derived from the rendered font would make the daemon's min-per-axis
/// grid a one-way ratchet the phone could never escape when the constraining
/// device grows back.
///
/// The rendered font itself never adapts to the granted grid. A grant smaller
/// than this capacity letterboxes at the user's font; a stretch-to-fill fit
/// used to live here and re-derived the rendered font from the grant, which
/// momentarily zoomed the terminal whenever the grant was stale (reconnect
/// replays, keyboard transitions).
public struct TerminalRowCapacityFit {
    /// The grid container height in device pixels.
    public let containerPixelHeight: CGFloat
    /// The measured cell height in device pixels at ``liveFontSize``.
    public let cellPixelHeight: CGFloat
    /// The font currently rendering (the one the cell was measured at).
    public let liveFontSize: Float32
    /// The grid container width in device pixels, when horizontal capacity is measured.
    private let containerPixelWidth: CGFloat?
    /// The measured cell width in device pixels at ``liveFontSize``, when horizontal capacity is measured.
    private let cellPixelWidth: CGFloat?

    /// Creates a fit over one two-axis geometry measurement, or nil when any
    /// input is not measurable yet (pre-layout zeroes).
    public init?(
        containerPixelHeight: CGFloat,
        cellPixelHeight: CGFloat,
        containerPixelWidth: CGFloat,
        cellPixelWidth: CGFloat,
        liveFontSize: Float32
    ) {
        guard containerPixelHeight > 0, cellPixelHeight > 0, liveFontSize > 0,
              containerPixelWidth > 0, cellPixelWidth > 0 else { return nil }
        self.containerPixelHeight = containerPixelHeight
        self.cellPixelHeight = cellPixelHeight
        self.liveFontSize = liveFontSize
        self.containerPixelWidth = containerPixelWidth
        self.cellPixelWidth = cellPixelWidth
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

    /// The column capacity this device should REPORT: how many columns fit in
    /// the container at the user's base font. Cell width scales linearly with
    /// the font point size, so the base-font cell width is derived from the
    /// measured live cell without a second libghostty round trip.
    public func capacityColumns(atBaseFontSize baseFontSize: Float32) -> Int? {
        guard let containerPixelWidth, let cellPixelWidth, baseFontSize > 0 else { return nil }
        let baseCellWidth = cellPixelWidth * CGFloat(baseFontSize) / CGFloat(liveFontSize)
        guard baseCellWidth > 0 else { return nil }
        return max(1, Int((containerPixelWidth / baseCellWidth).rounded(.down)))
    }
}
