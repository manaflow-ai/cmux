// SPDX-License-Identifier: MIT

/// One row of cells with the soft-wrap flags needed to losslessly stitch
/// wrapped logical lines back together (`WRAP` and `WRAP_CONTINUATION`).
public struct CellRow: Hashable, Sendable, Codable {
    /// `true` when this row was hard-wrapped at the right margin and the
    /// next row continues the same logical line.
    public let wrap: Bool
    /// `true` when this row is the continuation of a logical line that
    /// started on a previous row.
    public let wrapContinuation: Bool
    /// The cells in this row, left to right.
    public let cells: [Cell]

    /// Creates a row from its wrap flags and cells.
    public init(wrap: Bool, wrapContinuation: Bool, cells: [Cell]) {
        self.wrap = wrap
        self.wrapContinuation = wrapContinuation
        self.cells = cells
    }

    enum CodingKeys: String, CodingKey {
        case wrap
        case wrapContinuation = "wrap_continuation"
        case cells
    }
}
