import Foundation

/// A terminal's rendering grid, expressed in both character cells and the
/// pixel dimensions those cells occupy.
///
/// This is the value the paired-Mac surface reports back to the mobile client
/// on every attach, resize, and detach. ``columns`` and ``rows`` describe the
/// authoritative cell grid the daemon renders at; ``pixelWidth`` and
/// ``pixelHeight`` describe the surface's backing-store size in device pixels,
/// used by the host view to letterbox the rendered grid inside its container.
///
/// All four fields are independent integers, so two grids are ``Equatable``
/// only when their cell counts *and* pixel extents match.
///
/// ```swift
/// let natural = TerminalGridSize(columns: 100, rows: 32, pixelWidth: 900, pixelHeight: 650)
/// ```
public struct TerminalGridSize: Equatable, Hashable, Sendable, Codable {
    /// The number of character columns in the grid.
    public var columns: Int
    /// The number of character rows in the grid.
    public var rows: Int
    /// The grid's backing-store width in device pixels.
    public var pixelWidth: Int
    /// The grid's backing-store height in device pixels.
    public var pixelHeight: Int

    /// Creates a grid size from explicit cell counts and pixel dimensions.
    ///
    /// - Parameters:
    ///   - columns: The number of character columns.
    ///   - rows: The number of character rows.
    ///   - pixelWidth: The backing-store width in device pixels.
    ///   - pixelHeight: The backing-store height in device pixels.
    public init(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}
